#!/usr/bin/env bash
set -euo pipefail

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
                  items per array, and example-less enum fields get the
                  literal "example_value" (violates the spec's own enum;
                  warned about in the output).

  conformance     validate recorded/replayed RRPair response bodies against
                  an OpenAPI spec via the bundled check_conformance.py.
                  proxymock has NO native path for this (nothing in
                  generate/report/replay/files-compare/drift accepts a
                  spec; --fail-if is metrics-only). Checks type, required,
                  enum, and undocumented fields, with $ref resolution.

Shared options:
  --spec FILE           OpenAPI 3.0+ spec, .json or .yaml (YAML needs
                        PyYAML or ruby; else convert to .json first)
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

conformance options (forwarded to check_conformance.py):
  --in DIR              RRPair directory to check (a recording, one host
                        subdir of it, or a replay output dir)
  --paths REGEX         Only check pairs whose request path matches
  --fail-on-undocumented  Treat undocumented response fields as violations

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
  conformance:    summary.json (per-pair verdicts and counts)
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
die() {
  echo "error: $*" >&2
  exit 4
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
  fi
}

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$script_dir/check_conformance.py"

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
[[ -f "$checker" ]] || die "bundled checker missing: $checker"
[[ -n "$spec" ]] || die "--spec is required"
[[ -f "$spec" ]] || die "spec not found: $spec"
spec="$(abs_path "$spec")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-contract-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"
summary_json="$work_dir/summary.json"

# --- mode: conformance --------------------------------------------------------
if [[ "$mode" == "conformance" ]]; then
  [[ -n "$in_dir" ]] || die "conformance mode requires --in <rrpair dir>"
  [[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
  args=(--spec "$spec" --in "$in_dir" --summary "$summary_json")
  [[ -n "$paths_regex" ]] && args+=(--paths "$paths_regex")
  [[ "$fail_on_undocumented" == "1" ]] && args+=(--fail-on-undocumented)
  rc=0
  python3 "$checker" "${args[@]}" || rc=$?
  echo "summary: $summary_json"
  exit "$rc"
fi

# --- mode: mock-from-spec -----------------------------------------------------
if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

[[ -n "$out_dir" ]] || out_dir="$work_dir/generated"
mkdir -p "$out_dir"
out_dir="$(abs_path "$out_dir")"
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
echo "note: 2 identical stub items, one response per status, path params are"
echo "note: match-any templates, and https spec servers are emitted as"
echo "note: http://:80 in the artifacts (signature matching still works)."

# Enum fields without an example generate the literal "example_value",
# which violates the spec's own enum: apps that branch on those values will
# see impossible data. Warn whenever the spec has such fields.
enum_gaps="$(python3 "$checker" --spec "$spec" --enum-gaps)"
if [[ -n "$enum_gaps" ]]; then
  echo "WARNING: this spec has enum fields without examples; generated bodies" >&2
  echo "WARNING: will contain the literal \"example_value\" there, which violates" >&2
  echo "WARNING: the spec's own enum. Affected locations:" >&2
  while IFS= read -r line; do
    echo "WARNING:   ${line#enum-without-example: }" >&2
  done <<<"$enum_gaps"
fi

mock_cmd="$proxymock_bin mock --in $out_dir"

serve_pid=""
serve_ok="false"
if [[ "$serve" == "1" ]]; then
  need_cmd curl
  need_cmd lsof
  proxy_out_port="$(pick_port)"
  health_port="$(pick_port)"
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
    kill "$serve_pid" 2>/dev/null || true
    wait "$serve_pid" 2>/dev/null || true
    lsof -ti "tcp:${proxy_out_port}" 2>/dev/null | xargs kill 2>/dev/null || true
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
