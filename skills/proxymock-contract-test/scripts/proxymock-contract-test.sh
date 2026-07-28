#!/usr/bin/env bash
set -euo pipefail

# shared ql_* helpers; a copied skill needs skills/lib/common.sh too
if [[ ! -r "$(dirname "$0")/../../lib/common.sh" ]]; then
  echo "error: missing $(dirname "$0")/../../lib/common.sh (copy skills/lib/common.sh alongside this skill)" >&2
  exit 4
fi
source "$(dirname "$0")/../../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  proxymock-contract-test.sh mock-from-spec --spec FILE [options]
  proxymock-contract-test.sh conformance --spec FILE --in DIR [options]
  proxymock-contract-test.sh --mode <mock-from-spec|conformance> ...

Tier 1 contract testing from traffic plus OpenAPI, in two directions:

  mock-from-spec  wrap `proxymock generate` (OpenAPI 3.0+ JSON/YAML) so a
                  consumer can develop against the dependency's contract
                  before any recording exists. Prints the `proxymock mock
                  --in <generated>` command, or starts it with --serve.
                  Generated payloads are skeleton-grade (smoke/plumbing
                  tier): required-only fields by default, 2 identical stub
                  items per array, and example-less string fields get the
                  literal "example_value" (enum fields get a real member of
                  their enum).

  conformance     validate recorded/replayed RRPair response bodies against
                  an OpenAPI spec. This is a thin wrapper over the native
                  `proxymock validate --spec ... --in ...`, which checks
                  type, required, enum, and undocumented fields with $ref
                  resolution. The wrapper adds --paths filtering, the
                  undocumented-fields policy, and summary.json.

Shared options:
  --spec FILE           OpenAPI 3.0+ spec, .json, .yaml, or .yml (parsed by
                        proxymock; no python YAML dependency)
  --work-dir DIR        Where to write outputs (default: timestamped dir)
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

mock-from-spec options (mirroring `proxymock generate`):
  --out DIR             Where the generated RRPairs go (default:
                        WORK_DIR/generated)
  --direction D         outbound (default; mocks for `proxymock mock`),
                        inbound (tests for `proxymock replay`), or both
  --host HOST           Override host from the spec
  --port PORT           Override port for the mock server
  --include-optional    Include optional properties (recommended: default
                        required-only bodies are very sparse)
  --examples-only       Generate only responses with explicit examples
  --include-paths P     Comma-separated path patterns to include
  --exclude-paths P     Comma-separated path patterns to exclude
  --serve               Start `proxymock mock --in <generated>` after
                        generating (writes serve.json and mock.log)

conformance options:
  --in DIR              RRPair directory to check (a recording, one host
                        subdir of it, or a replay output dir). Passed to
                        `proxymock validate --in`.
  --paths REGEX         Only report pairs whose request path matches. No
                        native equivalent; applied as a filter over the
                        validate output, so the counts and the exit code
                        describe the kept pairs.
  --fail-on-undocumented  Treat undocumented response fields as violations.
                        Native validate ALWAYS does; without this flag the
                        wrapper downgrades undocumented-field findings to
                        notes, which keeps additive response fields
                        non-breaking.

Exit codes:
  0  mock-from-spec: generated (and, with --serve, the mock loaded)
     conformance: every checked pair conforms to the spec
  2  conformance: violations found (exact JSON path, field, expected,
     actual per finding)
  3  conformance: no violations, but the spec has no route for a checked
     pair (partial coverage; the pairs are named)
  4  precondition/usage error (bad args, unreadable spec, generate
     produced nothing, --serve mock failed to load)

Output files (in --work-dir):
  conformance:    summary.json (per-pair verdicts and counts), validate.out
                  (raw `proxymock validate` output)
  mock-from-spec: generated/ (unless --out), generate.log, summary.json,
                  and with --serve: serve.json, mock.log

Examples:
  # check the committed recording's outbound pairs against the spec
  proxymock-contract-test.sh conformance \
    --spec lab/openapi.yaml --in lab/proxymock/recording/demo-api.trafficreplay.com

  # mock the dependency straight from its spec, no recording needed
  proxymock-contract-test.sh mock-from-spec \
    --spec lab/openapi.yaml --include-optional --serve
USAGE
}

# precondition/usage failures are exit 4 per the output contract
die() { ql_die 4 "$@"; }
need_cmd() { ql_need_cmd "$1" 4; }

mode=""
spec=""
work_dir=""
proxymock_bin="${PROXYMOCK:-proxymock}"
# mock-from-spec
out_dir=""
direction="outbound"
host_override=""
port_override=""
include_optional="0"
examples_only="0"
include_paths=""
exclude_paths=""
serve="0"
# conformance
in_dir=""
paths_regex=""
fail_on_undocumented="0"

if [[ $# -ge 1 ]]; then
  case "$1" in
    mock-from-spec|conformance) mode="$1"; shift ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) [[ $# -ge 2 ]] || die "--mode requires a value"; mode="$2"; shift 2 ;;
    --spec) [[ $# -ge 2 ]] || die "--spec requires a value"; spec="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out requires a value"; out_dir="$2"; shift 2 ;;
    --direction) [[ $# -ge 2 ]] || die "--direction requires a value"; direction="$2"; shift 2 ;;
    --host) [[ $# -ge 2 ]] || die "--host requires a value"; host_override="$2"; shift 2 ;;
    --port) [[ $# -ge 2 ]] || die "--port requires a value"; port_override="$2"; shift 2 ;;
    --include-optional) include_optional="1"; shift ;;
    --examples-only) examples_only="1"; shift ;;
    --include-paths) [[ $# -ge 2 ]] || die "--include-paths requires a value"; include_paths="$2"; shift 2 ;;
    --exclude-paths) [[ $# -ge 2 ]] || die "--exclude-paths requires a value"; exclude_paths="$2"; shift 2 ;;
    --serve) serve="1"; shift ;;
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --paths) [[ $# -ge 2 ]] || die "--paths requires a value"; paths_regex="$2"; shift 2 ;;
    --fail-on-undocumented) fail_on_undocumented="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$mode" in
  mock-from-spec|conformance) ;;
  "") usage >&2; die "a mode is required: mock-from-spec or conformance" ;;
  *) die "unknown mode: $mode" ;;
esac

need_cmd python3
ql_check_proxymock_bin "$proxymock_bin" 4
[[ -n "$spec" ]] || die "--spec is required"
[[ -f "$spec" ]] || die "spec not found: $spec"
spec="$(ql_abs_path "$spec")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-contract-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(ql_abs_path "$work_dir")"
summary_json="$work_dir/summary.json"

# --- mode: conformance --------------------------------------------------------
if [[ "$mode" == "conformance" ]]; then
  [[ -n "$in_dir" ]] || die "conformance mode requires --in <rrpair dir>"
  [[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
  in_dir="$(ql_abs_path "$in_dir")"
  raw="$work_dir/validate.out"

  # no pipe: a pipeline reports the LAST command's status, which would hide
  # validate's 0/2/3 verdict codes
  native_rc=0
  "$proxymock_bin" validate --spec "$spec" --in "$in_dir" >"$raw" 2>&1 || native_rc=$?
  case "$native_rc" in
    0|2|3) ;;
    *) cat "$raw" >&2; die "proxymock validate failed (exit $native_rc)" ;;
  esac

  rc=0
  python3 - "$raw" "$summary_json" "$native_rc" "$paths_regex" \
    "$fail_on_undocumented" "$spec" "$in_dir" <<'PY' || rc=$?
import json, re, sys

raw, summary_path, native_rc, paths_regex, strict_arg, spec, in_dir = sys.argv[1:8]
native_rc = int(native_rc)
strict = strict_arg == "1"

# `proxymock validate` line shapes:
#   VERDICT METHOD PATH (STATUS)  [FILE]
#     <finding>            <- indented, belongs to the pair above
#   checked N pair(s): A conformant, B violating, C without a spec route
PAIR_RE = re.compile(r"^(CONFORMANT|VIOLATION|NO_ROUTE)\s+(\S+)\s+(\S+)\s+\((\d+|\?)\)\s+\[(.*)\]$")
TOTAL_RE = re.compile(r"^checked (\d+) pair")
UNDOC_RE = re.compile(r":\s+undocumented field\b")

pairs, total = [], None
for line in open(raw).read().splitlines():
    m = PAIR_RE.match(line)
    if m:
        verdict, method, path, status, f = m.groups()
        pairs.append({"file": f, "method": method, "path": path,
                      "status": int(status) if status.isdigit() else None,
                      "nativeVerdict": verdict, "findings": []})
        continue
    m = TOTAL_RE.match(line)
    if m:
        total = int(m.group(1))
        continue
    if line.startswith("  ") and line.strip() and pairs:
        pairs[-1]["findings"].append(line.strip())

# this wrapper reads validate's text output, so a format change must be loud
# rather than silently mis-summarized
if total is None or total != len(pairs):
    print("error: could not parse `proxymock validate` output (parsed %d pair(s), "
          "it reported %s). proxymock version skew? raw output: %s"
          % (len(pairs), total, raw), file=sys.stderr)
    sys.exit(4)


def judge(pair, strict):
    """Verdict, violations, notes. Native counts undocumented fields as
    violations unconditionally; we downgrade them unless --fail-on-undocumented."""
    if pair["nativeVerdict"] == "NO_ROUTE":
        return "NO_ROUTE", [], []
    violations, notes = [], []
    for f in pair["findings"]:
        (violations if strict or not UNDOC_RE.search(f) else notes).append(f)
    return ("VIOLATION" if violations else "CONFORMANT"), violations, notes


def exit_code(results):
    if any(r["verdict"] == "VIOLATION" for r in results):
        return 2
    if any(r["verdict"] == "NO_ROUTE" for r in results):
        return 3
    return 0


def build(keep, strict):
    out = []
    for p in keep:
        verdict, violations, notes = judge(p, strict)
        out.append({"file": p["file"], "method": p["method"], "path": p["path"],
                    "status": p["status"], "verdict": verdict,
                    "violations": violations, "undocumented": notes})
    return out


# unfiltered + strict reproduces native exactly: a mismatch means the parse
# drifted from what validate actually reported
if exit_code(build(pairs, True)) != native_rc:
    print("error: parsed verdicts disagree with `proxymock validate` exit %d; see %s"
          % (native_rc, raw), file=sys.stderr)
    sys.exit(4)

path_filter = re.compile(paths_regex) if paths_regex else None
kept = [p for p in pairs if not path_filter or path_filter.search(p["path"])]
if not kept:
    print("error: no RRPairs left to check under %s after the --paths filter %r"
          % (in_dir, paths_regex), file=sys.stderr)
    sys.exit(4)

results = build(kept, strict)
n_conf = sum(1 for r in results if r["verdict"] == "CONFORMANT")
n_viol = sum(1 for r in results if r["verdict"] == "VIOLATION")
n_none = sum(1 for r in results if r["verdict"] == "NO_ROUTE")
rc = exit_code(results)

for r in results:
    print("%-10s %s %s (%s)  [%s]" % (r["verdict"], r["method"], r["path"],
                                      r["status"] if r["status"] is not None else "?",
                                      r["file"]))
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

with open(summary_path, "w") as f:
    json.dump({"spec": spec, "inDir": in_dir, "pathsFilter": paths_regex or None,
               "failOnUndocumented": strict, "engine": "proxymock validate",
               "checked": len(results), "conformant": n_conf, "violating": n_viol,
               "noRoute": n_none, "results": results, "exitCode": rc},
              f, indent=2, sort_keys=True)
    f.write("\n")
sys.exit(rc)
PY
  if [[ -s "$summary_json" ]]; then echo "summary: $summary_json"; fi
  echo "raw validate output: $raw"
  exit "$rc"
fi

# --- mode: mock-from-spec -----------------------------------------------------
[[ -n "$out_dir" ]] || out_dir="$work_dir/generated"
mkdir -p "$out_dir"
out_dir="$(ql_abs_path "$out_dir")"
gen_log="$work_dir/generate.log"

gen_args=(generate --out "$out_dir" --direction "$direction")
[[ -n "$host_override" ]] && gen_args+=(--host "$host_override")
[[ -n "$port_override" ]] && gen_args+=(--port "$port_override")
[[ "$include_optional" == "1" ]] && gen_args+=(--include-optional)
[[ "$examples_only" == "1" ]] && gen_args+=(--examples-only)
[[ -n "$include_paths" ]] && gen_args+=(--include-paths "$include_paths")
[[ -n "$exclude_paths" ]] && gen_args+=(--exclude-paths "$exclude_paths")
gen_args+=("$spec")

echo "generating RRPairs from spec: $spec"
gen_rc=0
"$proxymock_bin" "${gen_args[@]}" >"$gen_log" 2>&1 || gen_rc=$?
if [[ "$gen_rc" -ne 0 ]]; then
  cat "$gen_log" >&2
  die "proxymock generate failed (exit $gen_rc); see $gen_log"
fi
pair_count="$(find "$out_dir" -type f -name '*.md' | wc -l | tr -d ' ')"
if [[ "$pair_count" -eq 0 ]]; then
  cat "$gen_log" >&2
  die "generate produced no RRPairs in $out_dir"
fi
echo "generated: $pair_count RRPair(s) in $out_dir (log: $gen_log)"

# Measured limits of generated payloads; keep expectations at smoke tier.
echo "note: generated bodies are skeleton-grade: required-only fields by"
echo "note: default (pass --include-optional for fuller bodies), arrays are"
echo "note: 2 identical stub items, one response per status, and path params"
echo "note: are match-any templates - including params the spec constrains"
echo "note: with an enum. Example-less string fields get the literal"
echo "note: \"example_value\"; enum fields get a real member of their enum."

mock_cmd="$proxymock_bin mock --in $out_dir"

serve_pid=""
serve_ok="false"
if [[ "$serve" == "1" ]]; then
  need_cmd curl
  need_cmd lsof
  proxy_out_port="$(ql_pick_port)"
  health_port="$(ql_pick_port)"
  mock_log="$work_dir/mock.log"
  echo "starting mock from generated RRPairs (proxy-out $proxy_out_port, health $health_port)"
  "$proxymock_bin" mock \
    --in "$out_dir" \
    --proxy-out-port "$proxy_out_port" \
    --health-port "$health_port" \
    --no-out \
    --log-to "$mock_log" >/dev/null 2>&1 &
  serve_pid=$!
  deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$serve_pid" 2>/dev/null; then
      break
    fi
    if curl -fsS -m 2 "http://127.0.0.1:${health_port}/" >/dev/null 2>&1; then
      if ! grep -q 'failed to read from directories' "$mock_log" 2>/dev/null; then
        serve_ok="true"
      fi
      break
    fi
    sleep 0.25
  done
  if [[ "$serve_ok" != "true" ]]; then
    ql_stop_pid_and_port "$serve_pid" "$proxy_out_port"
    echo "see $mock_log" >&2
    die "mock did not load the generated RRPairs"
  fi
  python3 - "$work_dir/serve.json" "$serve_pid" "$proxy_out_port" "$health_port" "$out_dir" <<'PY'
import json, sys
json.dump({
    "pid": int(sys.argv[2]),
    "proxyOutPort": int(sys.argv[3]),
    "healthPort": int(sys.argv[4]),
    "generatedDir": sys.argv[5],
}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
print()
PY
  echo "mock is up: route the app's outbound traffic through proxy port $proxy_out_port"
  echo "stop it with: kill $serve_pid (then sweep: lsof -ti tcp:$proxy_out_port | xargs kill)"
  echo "serve state: $work_dir/serve.json"
else
  echo "next: $mock_cmd"
fi

python3 - "$summary_json" "$spec" "$out_dir" "$pair_count" "$direction" \
  "$mock_cmd" "$serve_ok" <<'PY'
import json, sys
summary, spec, out_dir, pair_count, direction, mock_cmd, serve_ok = sys.argv[1:8]
json.dump({
    "mode": "mock-from-spec",
    "spec": spec,
    "generatedDir": out_dir,
    "pairCount": int(pair_count),
    "direction": direction,
    "mockCommand": mock_cmd,
    "served": serve_ok == "true",
}, open(summary, "w"), indent=2, sort_keys=True)
PY
echo "summary: $summary_json"
exit 0
