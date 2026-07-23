#!/usr/bin/env python3
"""Validate RRPair response bodies against an OpenAPI 3.0+ spec.

proxymock has no native traffic-vs-spec path (nothing in generate/report/
replay/files-compare/drift accepts a spec; --fail-if is metrics-only), so
the contract-test skill bundles this checker. Stdlib only, plus an optional
PyYAML import for YAML specs with a ruby -ryaml fallback.

Checks per JSON response body, with $ref resolution:
  - type (object/array/string/integer/number/boolean, nullable honored)
  - required fields
  - enum membership
  - undocumented fields (reported always; violations with --fail-on-undocumented)
  - undocumented response status for a documented route

Exit codes:
  0  every checked pair is conformant
  2  violations found
  3  no violations, but the spec has no route for a checked pair
  4  precondition/usage error (bad args, unreadable spec, no pairs)
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

INTERNAL_RE = re.compile(r"json:\s*(\{.*\})", re.S)
VALUE_TRUNC = 60


def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(4)


def load_spec(path):
    """Load a JSON or YAML OpenAPI spec as a dict.

    YAML fallback chain (needed in practice: PyYAML is often absent from the
    system python): PyYAML if importable, else ruby -ryaml, else require a
    .json spec.
    """
    p = pathlib.Path(path)
    if not p.is_file():
        fail("spec not found: %s" % path)
    text = p.read_text()
    if p.suffix.lower() == ".json":
        try:
            return json.loads(text)
        except ValueError as e:
            fail("spec is not valid JSON: %s (%s)" % (path, e))
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text)
    except ImportError:
        pass
    try:
        out = subprocess.run(
            ["ruby", "-ryaml", "-rjson", "-e",
             "puts JSON.generate(YAML.unsafe_load_file(ARGV[0]))", path],
            capture_output=True, text=True, check=True)
        return json.loads(out.stdout)
    except FileNotFoundError:
        fail("cannot read YAML spec: no PyYAML and no ruby on PATH; "
             "convert the spec to .json and retry")
    except subprocess.CalledProcessError as e:
        fail("ruby could not parse the YAML spec: %s" % e.stderr.strip())


def resolve_ref(schema, spec, seen=None):
    """Follow $ref chains within the spec document."""
    seen = seen or set()
    while isinstance(schema, dict) and "$ref" in schema:
        ref = schema["$ref"]
        if ref in seen:
            return {}
        seen.add(ref)
        if not ref.startswith("#/"):
            return {}
        node = spec
        for part in ref[2:].split("/"):
            if not isinstance(node, dict) or part not in node:
                return {}
            node = node[part]
        schema = node
    return schema if isinstance(schema, dict) else {}


def type_name(value):
    return type(value).__name__


def repr_trunc(value):
    r = repr(value)
    if len(r) > VALUE_TRUNC:
        r = r[:VALUE_TRUNC] + "..."
    return r


def check_type(value, expected, schema):
    if value is None:
        return bool(schema.get("nullable"))
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    return True


def validate(value, schema, spec, path, violations, undocumented):
    schema = resolve_ref(schema, spec)
    if not schema:
        return
    expected = schema.get("type")
    if expected and not check_type(value, expected, schema):
        violations.append("%s: type mismatch, expected %s, got %s (%s)"
                          % (path, expected, type_name(value), repr_trunc(value)))
        return
    if value is None:
        return
    if "enum" in schema and value not in schema["enum"]:
        violations.append("%s: enum violation, expected one of %s, got %s"
                          % (path, schema["enum"], repr_trunc(value)))
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for field in schema.get("required", []):
            if field not in value:
                violations.append("%s: required field '%s' missing" % (path, field))
        for key, sub in value.items():
            if key in props:
                validate(sub, props[key], spec, "%s.%s" % (path, key),
                         violations, undocumented)
            elif props and schema.get("additionalProperties") is not True:
                undocumented.append("%s.%s: undocumented field (not in spec properties)"
                                    % (path, key))
    elif isinstance(value, list):
        items = schema.get("items")
        if items:
            for i, item in enumerate(value):
                validate(item, items, spec, "%s[%d]" % (path, i),
                         violations, undocumented)


def route_table(spec):
    """[(regex, literal_segments, template, path_item)] sorted most-literal first."""
    table = []
    for template, item in (spec.get("paths") or {}).items():
        if not isinstance(item, dict):
            continue
        parts = template.strip("/").split("/")
        rx_parts, literals = [], 0
        for part in parts:
            if re.fullmatch(r"\{[^/}]+\}", part):
                rx_parts.append(r"[^/]+")
            else:
                rx_parts.append(re.escape(part))
                literals += 1
        rx = re.compile("^/" + "/".join(rx_parts) + "$")
        table.append((rx, literals, template, item))
    table.sort(key=lambda t: -t[1])
    return table


def find_route(table, path):
    for rx, _, template, item in table:
        if rx.match(path):
            return template, item
    return None, None


def parse_rrpair(md_path):
    """Extract method, path, status, direction, and response body from one RRPair file."""
    text = md_path.read_text(errors="ignore")
    if "### REQUEST ###" not in text:
        return None
    pair = {"file": str(md_path), "method": None, "path": None,
            "status": None, "direction": None, "body": None,
            "contentType": None}
    m = INTERNAL_RE.search(text)
    if m:
        try:
            rr = json.loads(m.group(1))
            http = rr.get("http", {})
            pair["method"] = http.get("req", {}).get("method")
            pair["path"] = http.get("req", {}).get("uri")
            pair["status"] = http.get("res", {}).get("statusCode")
            pair["contentType"] = http.get("res", {}).get("contentType")
            pair["direction"] = rr.get("direction")
        except ValueError:
            pass
    if not pair["method"] or not pair["path"]:
        # fall back to the markdown request line: "GET http://host:port/path HTTP/1.1"
        req = text.split("### REQUEST ###", 1)[1]
        blocks = re.findall(r"```\n(.*?)```", req, re.S)
        if blocks:
            first = blocks[0].strip().splitlines()
            if first:
                parts = first[0].split()
                if len(parts) >= 2:
                    pair["method"] = parts[0]
                    pair["path"] = re.sub(r"^\w+://[^/]+", "", parts[1]) or "/"
    if pair["path"]:
        pair["path"] = pair["path"].split("?", 1)[0]
    if "### RESPONSE ###" in text:
        res = text.split("### RESPONSE ###", 1)[1]
        res = res.split("### ", 1)[0]
        blocks = re.findall(r"```\n(.*?)```", res, re.S)
        if blocks and pair["status"] is None:
            status_line = blocks[0].strip().splitlines()
            if status_line:
                sm = re.match(r"HTTP/[\d.]+\s+(\d+)", status_line[0])
                if sm:
                    pair["status"] = int(sm.group(1))
        if len(blocks) >= 2:
            pair["body"] = blocks[1].strip()
    return pair if pair["method"] and pair["path"] else None


def enum_gaps(spec, node=None, path="$"):
    """Locations where an enum has no example/default sibling: proxymock
    generate fills these with the literal 'example_value', which violates
    the spec's own enum."""
    if node is None:
        node = spec
    gaps = []
    if isinstance(node, dict):
        if "enum" in node and "example" not in node and "default" not in node:
            gaps.append(path)
        for k, v in node.items():
            gaps.extend(enum_gaps(spec, v, "%s.%s" % (path, k)))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            gaps.extend(enum_gaps(spec, v, "%s[%d]" % (path, i)))
    return gaps


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--spec", required=True, help="OpenAPI 3.0+ spec (.json or .yaml)")
    ap.add_argument("--in", dest="in_dir", help="RRPair directory to check")
    ap.add_argument("--paths", help="only check pairs whose path matches this regex")
    ap.add_argument("--fail-on-undocumented", action="store_true",
                    help="treat undocumented response fields as violations")
    ap.add_argument("--summary", help="write summary JSON here")
    ap.add_argument("--enum-gaps", action="store_true",
                    help="only scan the spec for enums without examples, then exit 0")
    args = ap.parse_args()

    spec = load_spec(args.spec)
    if not isinstance(spec, dict) or "paths" not in spec:
        fail("spec has no paths object: %s" % args.spec)

    if args.enum_gaps:
        for gap in enum_gaps(spec):
            print("enum-without-example: %s" % gap)
        sys.exit(0)

    if not args.in_dir:
        fail("--in is required (RRPair directory)")
    root = pathlib.Path(args.in_dir)
    if not root.is_dir():
        fail("--in is not a directory: %s" % args.in_dir)
    path_filter = re.compile(args.paths) if args.paths else None

    table = route_table(spec)
    results = []
    for md in sorted(root.rglob("*.md")):
        pair = parse_rrpair(md)
        if not pair:
            continue
        if path_filter and not path_filter.search(pair["path"]):
            continue
        verdict = {"file": pair["file"], "method": pair["method"],
                   "path": pair["path"], "status": pair["status"],
                   "direction": pair["direction"],
                   "violations": [], "undocumented": [], "route": None}
        template, item = find_route(table, pair["path"])
        if template is None:
            verdict["verdict"] = "NO_ROUTE"
            results.append(verdict)
            continue
        verdict["route"] = template
        op = item.get((pair["method"] or "").lower())
        if not isinstance(op, dict):
            verdict["verdict"] = "NO_ROUTE"
            results.append(verdict)
            continue
        responses = op.get("responses") or {}
        resp = responses.get(str(pair["status"])) or responses.get("default")
        if resp is None:
            verdict["violations"].append(
                "$: undocumented response status %s for %s %s"
                % (pair["status"], pair["method"], template))
        else:
            resp = resolve_ref(resp, spec)
            schema = ((resp.get("content") or {}).get("application/json") or {}).get("schema")
            body = pair["body"]
            is_json = "json" in (pair["contentType"] or "") or (
                body or "").lstrip()[:1] in ("{", "[")
            if schema and body and is_json:
                try:
                    value = json.loads(body)
                except ValueError as e:
                    verdict["violations"].append(
                        "$: response body is not valid JSON (%s)" % e)
                else:
                    validate(value, schema, spec, "$",
                             verdict["violations"], verdict["undocumented"])
        if args.fail_on_undocumented:
            verdict["violations"].extend(verdict["undocumented"])
            verdict["undocumented"] = []
        verdict["verdict"] = "VIOLATION" if verdict["violations"] else "CONFORMANT"
        results.append(verdict)

    if not results:
        fail("no RRPairs found to check under %s"
             % args.in_dir + (" (after --paths filter)" if path_filter else ""))

    n_conf = sum(1 for r in results if r["verdict"] == "CONFORMANT")
    n_viol = sum(1 for r in results if r["verdict"] == "VIOLATION")
    n_none = sum(1 for r in results if r["verdict"] == "NO_ROUTE")
    exit_code = 2 if n_viol else (3 if n_none else 0)

    for r in results:
        line = "%-10s %s %s (%s)" % (r["verdict"], r["method"], r["path"],
                                     r["status"] if r["status"] is not None else "?")
        print(line + "  [" + r["file"] + "]")
        for v in r["violations"]:
            print("  " + v)
        for u in r["undocumented"]:
            print("  note: " + u)
    print()
    print("checked %d pair(s): %d conformant, %d violating, %d without a spec route"
          % (len(results), n_conf, n_viol, n_none))
    if n_none:
        print("partial coverage: the spec has no route for the NO_ROUTE pair(s) above;")
        print("if that side is your own app, its contract is the recording, not this")
        print("spec (use proxymock-regression-test for that direction)")

    if args.summary:
        summary = {
            "spec": args.spec,
            "inDir": args.in_dir,
            "pathsFilter": args.paths,
            "failOnUndocumented": args.fail_on_undocumented,
            "checked": len(results),
            "conformant": n_conf,
            "violating": n_viol,
            "noRoute": n_none,
            "results": results,
            "exitCode": exit_code,
        }
        with open(args.summary, "w") as f:
            json.dump(summary, f, indent=2, sort_keys=True)
            f.write("\n")
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
