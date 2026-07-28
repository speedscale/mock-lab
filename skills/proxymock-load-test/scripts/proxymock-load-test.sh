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
  --sessions N         Replay N recorded sessions concurrently instead of
                       virtual users: each slot replays one recorded actor's
                       requests in order at recorded think-time. Overrides
                       --vus. Combinable with --for / --times.
  --stage SPEC         One leg of a load ramp, repeatable, run in order.
                       SPEC is comma-separated key=value:
                         vus=N | sessions=N   target for the stage
                         for=D                hold the stage for D
                         ramp=D               climb to the target over the
                                              first D of 'for' (min 5s)
                       Not combinable with --vus / --sessions / --for /
                       --times. Example:
                         --stage vus=5,for=30s --stage vus=50,for=2m,ramp=1m
  --fail-if COND       Fail (exit 1) when COND is true; repeatable. Examples:
                         --fail-if 'latency.p99>100'
                         --fail-if 'requests.result-match-pct<95'
                         --fail-if 'requests.failed!=0'
  --performance        High-throughput mode: passes 'proxymock replay
                       --load-test' so match scoring is skipped and matchPct
                       is not reported. Off by default. Start the mock side
                       with 'proxymock mock --no-out' for a pure-load run.
  --work-dir DIR       Where to write summary.json and result.json
  --proxymock PATH     proxymock binary (default: proxymock from PATH)
  -h, --help           Show this help

Notes:
  - If neither --for, --times nor --stage is given, the default is --for 10s.
  - Latency values are milliseconds.

Examples:
  proxymock-load-test.sh --in ./proxymock/recording/localhost \
    --test-against http://localhost:8080 --vus 8 --for 30s
  proxymock-load-test.sh --in ./proxymock --test-against http://localhost:8080 \
    --vus 4 --times 20 --fail-if 'latency.p99>150' --fail-if 'requests.failed!=0'
  proxymock-load-test.sh --in ./proxymock/recording/localhost \
    --test-against http://localhost:8080 --sessions 20 --for 2m
  proxymock-load-test.sh --in ./proxymock/recording/localhost \
    --test-against http://localhost:8080 \
    --stage vus=5,for=30s --stage vus=50,for=2m,ramp=1m
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
vus_set="0"
for_dur=""
times=""
sessions=""
stages=()
work_dir=""
proxymock_bin="${PROXYMOCK:-proxymock}"
performance="0"
fail_if=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --test-against) [[ $# -ge 2 ]] || die "--test-against requires a value"; target="$2"; shift 2 ;;
    --vus) [[ $# -ge 2 ]] || die "--vus requires a value"; vus="$2"; vus_set="1"; shift 2 ;;
    --for) [[ $# -ge 2 ]] || die "--for requires a value"; for_dur="$2"; shift 2 ;;
    --times) [[ $# -ge 2 ]] || die "--times requires a value"; times="$2"; shift 2 ;;
    --sessions) [[ $# -ge 2 ]] || die "--sessions requires a value"; sessions="$2"; shift 2 ;;
    --stage) [[ $# -ge 2 ]] || die "--stage requires a value"; stages+=("$2"); shift 2 ;;
    --fail-if) [[ $# -ge 2 ]] || die "--fail-if requires a value"; fail_if+=("$2"); shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    --performance) performance="1"; shift ;;
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

# reject 0 explicitly: upstream treats --sessions 0 as "session replay off" and
# silently falls back to its own VU default, which is not this script's default
[[ -z "$sessions" || "$sessions" =~ ^[1-9][0-9]*$ ]] || die "--sessions must be a positive integer: $sessions"

# proxymock rejects --stage alongside --vus/--sessions/--for/--times, so catch
# the combination here with a message naming our flags rather than letting the
# replay fail after the mock side is already under load.
if [[ ${#stages[@]} -gt 0 ]]; then
  [[ "$vus_set" == "0" ]] || die "--stage carries its own vus= per leg; drop --vus"
  [[ -z "$sessions" ]] || die "--stage carries its own sessions= per leg; drop --sessions"
  [[ -z "$for_dur" ]] || die "--stage carries its own for= per leg; drop --for"
  [[ -z "$times" ]] || die "--stage sets the load shape; drop --times"
elif [[ -z "$for_dur" && -z "$times" ]]; then
  # Default to a short duration-based load if the caller picked no shape knob.
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

# --performance skips match scoring, so a match-pct gate can never be
# evaluated honestly in that mode; refuse the combination up front.
if [[ "$performance" == "1" ]]; then
  for cond in "${fail_if[@]:-}"; do
    [[ "$cond" == *result-match-pct* ]] && die "--performance skips match scoring; a --fail-if on requests.result-match-pct cannot be evaluated (drop one of the two)"
  done
fi

replay_args=(replay --in "$in_dir" --test-against "$target" --output json --no-out)
if [[ ${#stages[@]} -gt 0 ]]; then
  # --stage is self-contained: it carries the VU/session target and duration of
  # every leg, and proxymock refuses it next to --vus/--sessions/--for/--times
  for stage in "${stages[@]}"; do
    replay_args+=(--stage "$stage")
  done
elif [[ -n "$sessions" ]]; then
  # --sessions overrides --vus upstream; pass only one so the intent is explicit
  replay_args+=(--sessions "$sessions")
else
  replay_args+=(--vus "$vus")
fi
if [[ "$performance" == "1" ]]; then
  # proxymock renamed this flag --load-test in v2.5.805; --performance still
  # works but prints a deprecation notice on every run
  replay_args+=(--load-test)
fi
if [[ -n "$for_dur" ]]; then
  replay_args+=(--for "$for_dur")
fi
if [[ -n "$times" ]]; then
  replay_args+=(--times "$times")
fi
for cond in "${fail_if[@]:-}"; do
  [[ -n "$cond" ]] && replay_args+=(--fail-if "$cond")
done

perf_note=""
if [[ "$performance" == "1" ]]; then
  perf_note=" [--performance: match scoring off]"
fi
if [[ ${#stages[@]} -gt 0 ]]; then
  shape="stages=$(IFS='|'; echo "${stages[*]}")"
elif [[ -n "$sessions" ]]; then
  shape="sessions=${sessions}"
else
  shape="vus=${vus}"
fi
echo "load test: ${shape} ${for_dur:+for=${for_dur} }${times:+times=${times} }-> ${target}${perf_note}"
replay_rc=0
"$proxymock_bin" "${replay_args[@]}" >"$result_json" 2>"$work_dir/replay.log" || replay_rc=$?

[[ -s "$result_json" ]] || { cat "$work_dir/replay.log" >&2; die "proxymock replay produced no JSON result (see $work_dir/replay.log)"; }

python3 - "$result_json" "$summary_json" "$replay_rc" "$performance" <<'PY'
import json, sys

result = json.load(open(sys.argv[1]))
summary_json = sys.argv[2]
replay_rc = int(sys.argv[3])
performance = sys.argv[4] == "1"

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

# --load-test omits requests.result-match-pct entirely because responses are
# not scored, so .get() already yields None; null it explicitly anyway to stay
# honest against any build that reports a meaningless 100 for the key.
if performance:
    summary["matchPct"] = None
    summary["matchPctNote"] = "n/a (--load-test skips match scoring)"
    for e in summary["perEndpoint"]:
        e["matchPct"] = None

with open(summary_json, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

lat = summary["latencyMs"]
if performance:
    mp_str = "match scoring off (--performance)"
else:
    mp = summary["matchPct"]
    mp_str = f"{mp:.1f}% match" if isinstance(mp, (int, float)) else f"{mp}% match"
print("\n=== load test summary ===")
print(f"requests   : {summary['totalRequests']} total · {summary['failed']} failed · {mp_str}")
print(f"throughput : {summary['rps']:.1f} req/s" if isinstance(summary['rps'], (int, float)) else f"throughput : {summary['rps']} req/s")
print(f"latency ms : p50={lat['p50']} p90={lat['p90']} p95={lat['p95']} p99={lat['p99']} max={lat['max']}")
print(f"summary    : {summary_json}")
PY

echo "summary: $summary_json"
if [[ "$replay_rc" -ne 0 ]]; then
  echo "one or more --fail-if conditions tripped (replay exit ${replay_rc})" >&2
  exit "$replay_rc"
fi
