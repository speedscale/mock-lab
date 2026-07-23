#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-regression-test.sh --in DIR --test-against URL [options]

Replay a recorded proxymock session at a target and gate on regressions:
per-RRPair result-match tags (pass/fail) and, with a baseline, budget flips
from a Compare report. requests.failed is NOT the gate: a status-code
regression (201 -> 200) completes the HTTP exchange cleanly and leaves
requests.failed at 0; only the match tag catches it.

Required:
  --in DIR              Recording directory to replay (RRPair files)
  --test-against URL    Target to replay against (e.g. http://localhost:8080)

Options:
  --baseline DIR        A prior known-good replay output directory. Enables
                        baseline-relative match gating (only NEW failures
                        count) and the budget-flip gate.
  --fail-on-regression  Exit nonzero when regressions are found; without it
                        findings are reported and the exit code is 0.
  --work-dir DIR        Where to write the replay output and reports
                        (default: timestamped dir)
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

Exit codes:
  0  no regression (or findings present without --fail-on-regression)
  2  precondition failure (bad args, missing dirs, replay did not run)
  3  match-tag regressions (with --fail-on-regression)
  4  budget flips (with --fail-on-regression; requires --baseline)

Output files (in --work-dir):
  replayed/             replay output RRPairs (use as --baseline next run)
  result.json           replay metrics (latency, requests.failed, match pct)
  report.json/.html/.prompt.md   proxymock report (Compare report with --baseline)
  summary.json          machine-readable verdict

Examples:
  # first run: establish a baseline replay
  proxymock-regression-test.sh --in ./proxymock/recording \
    --test-against http://localhost:8080 --work-dir ./regress-base

  # after a code change: gate against the known-good replay
  proxymock-regression-test.sh --in ./proxymock/recording \
    --test-against http://localhost:8080 \
    --baseline ./regress-base/replayed --fail-on-regression
USAGE
}

# precondition failures use a distinct exit code per the output contract
die() {
  echo "error: $*" >&2
  exit 2
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
baseline_dir=""
work_dir=""
fail_on_regression="0"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --test-against) [[ $# -ge 2 ]] || die "--test-against requires a value"; target="$2"; shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || die "--baseline requires a value"; baseline_dir="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --fail-on-regression) fail_on_regression="1"; shift ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$target" ]] || die "--test-against is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
[[ -z "$baseline_dir" || -d "$baseline_dir" ]] || die "--baseline is not a directory: $baseline_dir"

need_cmd python3
if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

in_dir="$(abs_path "$in_dir")"
[[ -n "$baseline_dir" ]] && baseline_dir="$(abs_path "$baseline_dir")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-regression-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"
replay_out="$work_dir/replayed"
result_json="$work_dir/result.json"
replay_log="$work_dir/replay.log"
summary_json="$work_dir/summary.json"

if [[ -d "$replay_out" ]] && [[ -n "$(ls -A "$replay_out" 2>/dev/null)" ]]; then
  die "replay output dir already has content, pick a fresh --work-dir: $replay_out"
fi

# --- precondition: blueprint anchoring ---------------------------------------
# Blueprints are loaded only from the --in path's parent proxymock directory's
# blueprints/ subdir, not from cwd and not from the output workspace (same
# anchoring rule as replay's own help text: "--out ... default anchors to the
# --in workspace, not the current directory"). Without a blueprint, endpoints
# that chain moving IDs (fresh tokens, created order ids) replay with stale
# recorded values, the target rejects them (401/404), and a regression on
# those endpoints' SUCCESS paths is undetectable: they fail before and after.
bp_dir="$(dirname "$in_dir")/blueprints"
bp_count=0
if [[ -d "$bp_dir" ]]; then
  bp_count="$(find "$bp_dir" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')"
fi
if [[ "$bp_count" -eq 0 ]]; then
  echo "WARNING: no blueprints found at $bp_dir" >&2
  echo "WARNING: auth/moving-ID endpoints will be unreplayable (401s) and any" >&2
  echo "WARNING: regression on their success paths is UNDETECTABLE (masked)." >&2
else
  echo "blueprints: $bp_count file(s) in $bp_dir"
fi

# --- precondition: mock reminder ---------------------------------------------
# If the recording has outbound pairs, the target app's downstream is usually
# served by `proxymock mock`, which does not discover the recording from cwd.
if grep -rl '"direction":"OUT"' "$in_dir" >/dev/null 2>&1; then
  echo "note: recording contains outbound pairs; if the target's downstream is"
  echo "note: mocked, 'proxymock mock' requires an explicit --in <recording>."
fi

# --- replay ------------------------------------------------------------------
echo "replaying: $in_dir -> $target"
replay_rc=0
"$proxymock_bin" replay \
  --in "$in_dir" \
  --test-against "$target" \
  --out "$replay_out" \
  --output json >"$result_json" 2>"$replay_log" || replay_rc=$?

if [[ "$replay_rc" -ne 0 || ! -s "$result_json" || ! -d "$replay_out" ]]; then
  cat "$replay_log" >&2
  die "proxymock replay did not complete (exit $replay_rc); see $replay_log"
fi

# The console line "Applied N active blueprint(s)" reflects snapshot-scoped
# state, not the workspace, so it can report blueprints that never touched
# this replay. The only trustworthy signal is smart_replace events in the
# replay output RRPairs.
if [[ "$bp_count" -gt 0 ]]; then
  sr_files="$( (grep -ril 'smart_replace' "$replay_out" 2>/dev/null || true) | wc -l | tr -d ' ')"
  if [[ "$sr_files" -eq 0 ]]; then
    echo "WARNING: blueprint(s) present but no smart_replace events found in the" >&2
    echo "WARNING: replay output; the blueprint did not demonstrably apply. Do not" >&2
    echo "WARNING: trust the 'Applied N active blueprint(s)' console line. Moving-ID" >&2
    echo "WARNING: endpoints may 401 and mask regressions on their success paths." >&2
  else
    echo "blueprint applied: smart_replace events in $sr_files replay RRPair file(s)"
  fi
fi

# --- report (Compare report when a baseline is given) ------------------------
base_args=(report --in "$replay_out")
if [[ -n "$baseline_dir" ]]; then
  base_args+=(--baseline "$baseline_dir")
fi
for fmt in json html prompt; do
  case "$fmt" in
    json) out="$work_dir/report.json" ;;
    html) out="$work_dir/report.html" ;;
    prompt) out="$work_dir/report.prompt.md" ;;
  esac
  "$proxymock_bin" "${base_args[@]}" --format "$fmt" --out "$out" --exit-zero
done

# --- gate: match tags + budget flips -----------------------------------------
rc=0
python3 - "$replay_out" "$baseline_dir" "$work_dir/report.json" "$result_json" \
  "$summary_json" "$fail_on_regression" <<'PY' || rc=$?
import json, pathlib, re, sys

replay_out, baseline_dir, report_json, result_json, summary_json, gate = sys.argv[1:7]
gate = gate == "1"

internal_re = re.compile(r"json:\s*(\{.*\})", re.S)

def scan(root):
    """refUuid -> pair info from the INTERNAL json of every RRPair file."""
    pairs = {}
    if not root:
        return pairs
    for path in sorted(pathlib.Path(root).rglob("*.md")):
        m = internal_re.search(path.read_text(errors="ignore"))
        if not m:
            continue
        try:
            rr = json.loads(m.group(1))
        except Exception:
            continue
        tags = rr.get("tags", {})
        ref = tags.get("refUuid")
        if not ref:
            continue
        http = rr.get("http", {})
        info = {
            "match": tags.get("match"),
            "method": http.get("req", {}).get("method"),
            "uri": http.get("req", {}).get("uri"),
            "observedStatus": http.get("res", {}).get("statusCode"),
            "sourceFile": tags.get("file"),
            "replayFile": str(path),
        }
        # aggregate duplicates (multi-pass replays): any fail wins
        prev = pairs.get(ref)
        if prev is None or info["match"] == "fail":
            pairs[ref] = info
    return pairs

def recorded_status(source_file):
    if not source_file:
        return None
    p = pathlib.Path(source_file)
    if not p.is_file():
        return None
    m = internal_re.search(p.read_text(errors="ignore"))
    if not m:
        return None
    try:
        rr = json.loads(m.group(1))
    except Exception:
        return None
    return rr.get("http", {}).get("res", {}).get("statusCode")

current = scan(replay_out)
if not current:
    print("error: no replay RRPairs with match tags found in " + replay_out, file=sys.stderr)
    sys.exit(2)

baseline = scan(baseline_dir)
if baseline_dir and not baseline:
    print("error: --baseline contains no replay RRPairs: " + baseline_dir, file=sys.stderr)
    sys.exit(2)

fails = {ref: p for ref, p in current.items() if p["match"] == "fail"}
baseline_fail_refs = {ref for ref, p in baseline.items() if p["match"] == "fail"}

# baseline-relative: a failure already present in the baseline is the known
# noise floor, not a regression; without a baseline every failure counts
if baseline:
    new_failures = {ref: p for ref, p in fails.items() if ref not in baseline_fail_refs}
else:
    new_failures = dict(fails)
for ref, p in new_failures.items():
    p["recordedStatus"] = recorded_status(p.get("sourceFile"))

flips = []
if baseline_dir:
    report = json.load(open(report_json))
    for b in (report.get("deltas") or {}).get("budgets") or []:
        if b.get("bPass") and not b.get("cPass"):
            flips.append({
                "metric": b.get("metric"),
                "op": b.get("op"),
                "value": b.get("value"),
                "unit": b.get("unit"),
                "baselineObserved": b.get("bObserved"),
                "currentObserved": b.get("cObserved"),
            })

result = json.load(open(result_json))
overall = next((e for e in result.get("endpoints", []) if e.get("url") == "-ALL-"), {})
metrics = overall.get("metrics", {})

exit_code = 0
if gate and new_failures:
    exit_code = 3
elif gate and flips:
    exit_code = 4

work_dir = str(pathlib.Path(summary_json).parent)
summary = {
    "replayDir": replay_out,
    "baselineDir": baseline_dir or None,
    "requestsTotal": metrics.get("requests.total"),
    "requestsFailed": metrics.get("requests.failed"),
    "resultMatchPct": metrics.get("requests.result-match-pct"),
    "match": {
        "pairs": len(current),
        "failures": len(fails),
        "baselineFailures": len(baseline_fail_refs) if baseline else None,
        "newFailures": [
            {"refUuid": ref, **{k: v for k, v in p.items() if k != "match"}}
            for ref, p in sorted(new_failures.items())
        ],
    },
    "budgetFlips": flips,
    "reports": {
        "json": work_dir + "/report.json",
        "html": work_dir + "/report.html",
        "prompt": work_dir + "/report.prompt.md",
    },
    "gated": gate,
    "exitCode": exit_code,
}
with open(summary_json, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

print("")
print("=== regression verdict ===")
print(f"requests    : {summary['requestsTotal']} total, {summary['requestsFailed']} transport-failed")
print(f"match tags  : {len(current)} pairs, {len(fails)} fail"
      + (f" ({len(baseline_fail_refs)} in baseline noise floor)" if baseline else " (no baseline: all count)"))
for ref, p in sorted(new_failures.items()):
    rec = p.get("recordedStatus")
    rec_s = str(rec) if rec is not None else "?"
    print(f"  NEW FAIL  : {p['method']} {p['uri']} recorded {rec_s} -> observed {p['observedStatus']}")
for f_ in flips:
    print(f"  BUDGET FLIP: {f_['metric']} {f_['op']} {f_['value']}{f_['unit'] or ''} "
          f"(baseline {f_['baselineObserved']} pass -> current {f_['currentObserved']} fail)")
if not new_failures and not flips:
    print("no regressions detected")
print(f"replay dir  : {replay_out}")
print(f"summary     : {summary_json}")
print(f"digest      : {work_dir}/report.prompt.md")
sys.exit(exit_code)
PY

if [[ "$rc" -eq 3 ]]; then
  echo "FAIL: match-tag regression(s) detected" >&2
elif [[ "$rc" -eq 4 ]]; then
  echo "FAIL: budget flip(s) detected" >&2
fi
exit "$rc"
