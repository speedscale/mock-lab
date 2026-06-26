#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-load-test.sh --in DIR --test-against URL [options]

Drive a quick load test by replaying recorded RRPair traffic at a target with
multiple virtual users, then summarize latency percentiles, throughput, and
match rate.

Required:
  --in DIR             Directory of test/recording RRPair files to replay
  --test-against URL   Target to replay against (e.g. http://localhost:8080)

Options:
  --vus N              Parallel virtual users (default: 4)
  --for DURATION       Run for a Go duration (e.g. 30s, 2m). Loops the traffic.
  --times N            Replay the whole set N times (default: 1 if --for unset)
  --fail-if COND       Fail (exit 1) when COND is true; repeatable. Examples:
                         --fail-if 'latency.p99>100'
                         --fail-if 'requests.result-match-pct<95'
                         --fail-if 'requests.failed!=0'
  --work-dir DIR       Where to write summary.json and result.json
  --proxymock PATH     proxymock binary (default: proxymock from PATH)
  -h, --help           Show this help

Notes:
  - If neither --for nor --times is given, the default is --for 10s.
  - Latency values are milliseconds.

Examples:
  proxymock-load-test.sh --in ./proxymock/recording/localhost \
    --test-against http://localhost:8080 --vus 8 --for 30s
  proxymock-load-test.sh --in ./proxymock --test-against http://localhost:8080 \
    --vus 4 --times 20 --fail-if 'latency.p99>150' --fail-if 'requests.failed!=0'
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
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

in_dir=""
target=""
vus="4"
for_dur=""
times=""
work_dir=""
proxymock_bin="${PROXYMOCK:-proxymock}"
fail_if=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --test-against) [[ $# -ge 2 ]] || die "--test-against requires a value"; target="$2"; shift 2 ;;
    --vus) [[ $# -ge 2 ]] || die "--vus requires a value"; vus="$2"; shift 2 ;;
    --for) [[ $# -ge 2 ]] || die "--for requires a value"; for_dur="$2"; shift 2 ;;
    --times) [[ $# -ge 2 ]] || die "--times requires a value"; times="$2"; shift 2 ;;
    --fail-if) [[ $# -ge 2 ]] || die "--fail-if requires a value"; fail_if+=("$2"); shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$target" ]] || die "--test-against is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"

need_cmd python3
if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

# Default to a short duration-based load if the caller picked neither knob.
if [[ -z "$for_dur" && -z "$times" ]]; then
  for_dur="10s"
fi

in_dir="$(abs_path "$in_dir")"
if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-load-test-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"

result_json="$work_dir/result.json"
summary_json="$work_dir/summary.json"

replay_args=(replay --in "$in_dir" --test-against "$target" --vus "$vus" --output json --no-out)
if [[ -n "$for_dur" ]]; then
  replay_args+=(--for "$for_dur")
fi
if [[ -n "$times" ]]; then
  replay_args+=(--times "$times")
fi
for cond in "${fail_if[@]:-}"; do
  [[ -n "$cond" ]] && replay_args+=(--fail-if "$cond")
done

echo "load test: vus=${vus} ${for_dur:+for=${for_dur} }${times:+times=${times} }-> ${target}"
replay_rc=0
"$proxymock_bin" "${replay_args[@]}" >"$result_json" 2>"$work_dir/replay.log" || replay_rc=$?

[[ -s "$result_json" ]] || { cat "$work_dir/replay.log" >&2; die "proxymock replay produced no JSON result (see $work_dir/replay.log)"; }

python3 - "$result_json" "$summary_json" "$replay_rc" <<'PY'
import json, sys

result = json.load(open(sys.argv[1]))
summary_json = sys.argv[2]
replay_rc = int(sys.argv[3])

endpoints = result.get("endpoints", [])
overall = next((e for e in endpoints if e.get("url") == "-ALL-"), None)
if overall is None and endpoints:
    overall = endpoints[0]
m = (overall or {}).get("metrics", {})

summary = {
    "target": None,
    "totalRequests": m.get("requests.total", 0),
    "succeeded": m.get("requests.succeeded", 0),
    "failed": m.get("requests.failed", 0),
    "matchPct": m.get("requests.result-match-pct"),
    "responsePct": m.get("requests.response-pct"),
    "rps": m.get("requests.per-second"),
    "rpm": m.get("requests.per-minute"),
    "latencyMs": {
        "min": m.get("latency.min"),
        "avg": m.get("latency.avg"),
        "p50": m.get("latency.p50"),
        "p90": m.get("latency.p90"),
        "p95": m.get("latency.p95"),
        "p99": m.get("latency.p99"),
        "max": m.get("latency.max"),
    },
    "perEndpoint": [
        {
            "method": e.get("method"),
            "url": e.get("url"),
            "total": e.get("metrics", {}).get("requests.total"),
            "failed": e.get("metrics", {}).get("requests.failed"),
            "matchPct": e.get("metrics", {}).get("requests.result-match-pct"),
            "p99Ms": e.get("metrics", {}).get("latency.p99"),
        }
        for e in endpoints if e.get("url") != "-ALL-"
    ],
    "failIfExitCode": replay_rc,
    "resultJson": sys.argv[1],
}

with open(summary_json, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

lat = summary["latencyMs"]
mp = summary["matchPct"]
mp_str = f"{mp:.1f}" if isinstance(mp, (int, float)) else str(mp)
print("\n=== load test summary ===")
print(f"requests   : {summary['totalRequests']} total · {summary['failed']} failed · {mp_str}% match")
print(f"throughput : {summary['rps']:.1f} req/s" if isinstance(summary['rps'], (int, float)) else f"throughput : {summary['rps']} req/s")
print(f"latency ms : p50={lat['p50']} p90={lat['p90']} p95={lat['p95']} p99={lat['p99']} max={lat['max']}")
print(f"summary    : {summary_json}")
PY

echo "summary: $summary_json"
if [[ "$replay_rc" -ne 0 ]]; then
  echo "one or more --fail-if conditions tripped (replay exit ${replay_rc})" >&2
  exit "$replay_rc"
fi
