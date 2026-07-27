#!/usr/bin/env bash
set -euo pipefail

# shared ql_* helpers; a copied skill needs skills/lib/common.sh too
if [[ ! -r "$(dirname "$0")/../../lib/common.sh" ]]; then
  echo "error: missing $(dirname "$0")/../../lib/common.sh (copy skills/lib/common.sh alongside this skill)" >&2
  exit 2
fi
source "$(dirname "$0")/../../lib/common.sh"

usage() {
  cat <<'USAGE'
Usage:
  proxymock-regression-test.sh --in DIR --test-against URL [options]

Replay a recorded proxymock session at a target and gate on regressions:
proxymock's native replay verdict (--baseline --fail-on-new-mismatch, read
from <out>/replay-verdict.json) and, with a baseline, budget flips from a
Compare report. requests.failed is NOT the gate: a status-code regression
(201 -> 200) completes the HTTP exchange cleanly and leaves requests.failed
at 0; only the verdict catches it.

replay scores response BODIES as well as status codes (v2.5.812 and later), so
a changed field is a mismatch on its own: the verdict reports bodyMatch and
per-pair bodyChanges, and the summary counts bodyMismatches. No separate
body-diff step is needed. Volatile-value suppression is heuristic and
undocumented, so it decides for you which churn is noise: pass a --baseline and
gate on new mismatches rather than trusting a raw zero.

Required:
  --in DIR              Recording directory to replay (RRPair files)
  --test-against URL    Target to replay against (e.g. http://localhost:8080)

Options:
  --baseline DIR        A prior known-good replay output directory. Enables
                        replay's native baseline-relative gating (only NEW
                        mismatches count) and the budget-flip gate.
  --fail-on-regression  Exit nonzero when regressions are found; without it
                        findings are reported and the exit code is 0.
  --work-dir DIR        Where to write the replay output and reports
                        (default: timestamped dir)
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

Exit codes:
  0  no regression (or findings present without --fail-on-regression)
  2  precondition failure (bad args, missing dirs, replay did not run)
  3  status or body regressions (with --fail-on-regression)
  4  budget flips (with --fail-on-regression; requires --baseline)

Output files (in --work-dir):
  replayed/             replay output RRPairs (use as --baseline next run)
  replayed/replay-verdict.json  proxymock's native per-pair verdict
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
die() { ql_die 2 "$@"; }
need_cmd() { ql_need_cmd "$1" 2; }

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
ql_check_proxymock_bin "$proxymock_bin" 2

in_dir="$(ql_abs_path "$in_dir")"
[[ -n "$baseline_dir" ]] && baseline_dir="$(ql_abs_path "$baseline_dir")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-regression-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(ql_abs_path "$work_dir")"
replay_out="$work_dir/replayed"
result_json="$work_dir/result.json"
replay_log="$work_dir/replay.log"
summary_json="$work_dir/summary.json"

ql_check_replay_out_empty "$replay_out" 2

# --- precondition: blueprint anchoring ---------------------------------------
# Blueprints are loaded only from the --in path's parent proxymock directory's
# blueprints/ subdir, not from cwd and not from the output workspace (same
# anchoring rule as replay's own help text: "--out ... default anchors to the
# --in workspace, not the current directory"). Without a blueprint, endpoints
# that chain moving IDs (fresh tokens, created order ids) replay with stale
# recorded values, the target rejects them (401/404), and a regression on
# those endpoints' SUCCESS paths is undetectable: they fail before and after.
bp_dir="$(ql_blueprint_dir "$in_dir")"
bp_count="$(ql_blueprint_count "$bp_dir")"
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
if ql_has_outbound "$in_dir"; then
  echo "note: recording contains outbound pairs; if the target's downstream is"
  echo "note: mocked, 'proxymock mock' requires an explicit --in <recording>."
fi

# --- replay (native verdict gate) --------------------------------------------
# --fail-on-new-mismatch requires --baseline (measured: it errors without one),
# so without a baseline the gate is applied locally over the verdict file,
# where every mismatch counts. With a baseline, replay's exit 3 IS the gate.
echo "replaying: $in_dir -> $target"
replay_flags=()
if [[ -n "$baseline_dir" ]]; then
  replay_flags+=(--baseline "$baseline_dir")
  [[ "$fail_on_regression" == "1" ]] && replay_flags+=(--fail-on-new-mismatch)
fi
ql_run_replay "$proxymock_bin" "$in_dir" "$target" "$replay_out" \
  "$result_json" "$replay_log" 2 \
  ${replay_flags[@]+"${replay_flags[@]}"}
replay_rc="$ql_replay_rc"
ql_echo_replay_verdict_lines "$replay_log"

# baseline masking is per-pair: flag pairs whose failure changed while staying
# classified known-mismatch (advisory, never a gate)
ql_advise_masked_different "$replay_out/replay-verdict.json" "$baseline_dir"

# smart_replace events in the replay output are the direct evidence a blueprint
# ran; "Loaded blueprint ..." only reports loading (see common.sh).
if [[ "$bp_count" -gt 0 ]]; then
  sr_files="$(ql_smart_replace_file_count "$replay_out")"
  if [[ "$sr_files" -eq 0 ]]; then
    echo "WARNING: blueprint(s) present but no smart_replace events found in the" >&2
    echo "WARNING: replay output; the blueprint did not demonstrably apply." >&2
    echo "WARNING: Moving-ID endpoints may 401 and mask regressions on their" >&2
    echo "WARNING: success paths." >&2
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

# --- gate: native verdict (status + body) + budget flips ----------------------
rc=0
python3 - "$replay_out" "$baseline_dir" "$work_dir/report.json" "$result_json" \
  "$summary_json" "$fail_on_regression" "$replay_rc" <<'PY' || rc=$?
import json, pathlib, sys

(replay_out, baseline_dir, report_json, result_json, summary_json, gate,
 replay_rc) = sys.argv[1:8]
gate = gate == "1"
replay_rc = int(replay_rc)

# proxymock writes this on every non-load-test replay; it carries the recorded
# and observed status, the body scoring (bodyMatch / bodyChanges), the baseline
# comparison and the gate decision per pair
verdict = json.load(open(pathlib.Path(replay_out) / "replay-verdict.json"))
pairs = verdict.get("pairs") or []
if not pairs:
    print("error: replay-verdict.json scored no pairs in " + replay_out, file=sys.stderr)
    sys.exit(2)

def row(p):
    return {
        "refUuid": p.get("refUuid"),
        "method": p.get("method"),
        "uri": p.get("endpoint"),
        "recordedStatus": p.get("recordedStatus"),
        "observedStatus": p.get("observedStatus"),
        "bodyMatch": p.get("bodyMatch"),
        "bodyChanges": p.get("bodyChanges") or [],
        "sourceFile": p.get("sourceFile"),
        "replayFile": p.get("replayFile"),
    }

# a pair fails when its status OR its body changed; bodyMatch is absent on
# pairs with no body to score, so a missing value is not a failure
def failed(p):
    return p.get("match") != "pass" or p.get("bodyMatch", "pass") != "pass"

fails = [p for p in pairs if failed(p)]
if baseline_dir:
    new_failures = [p for p in fails if p.get("newMismatch")]
else:
    new_failures = list(fails)

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

# replay's own exit 3 is the gate whenever a baseline was given; the local
# check covers the no-baseline case, where --fail-on-new-mismatch is rejected
exit_code = 0
if gate and (replay_rc == 3 or new_failures):
    exit_code = 3
elif gate and flips:
    exit_code = 4

vsummary = verdict.get("summary") or {}
work_dir = str(pathlib.Path(summary_json).parent)
summary = {
    "replayDir": replay_out,
    "baselineDir": baseline_dir or None,
    "requestsTotal": metrics.get("requests.total"),
    "requestsFailed": metrics.get("requests.failed"),
    "resultMatchPct": metrics.get("requests.result-match-pct"),
    "match": {
        "pairs": vsummary.get("pairs", len(pairs)),
        "failures": vsummary.get("mismatches", len(fails)),
        "bodyFailures": vsummary.get("bodyMismatches", 0),
        "baselineFailures": vsummary.get("baselineMismatches", 0) if baseline_dir else None,
        "newFailures": [row(p) for p in new_failures],
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

m = summary["match"]
print("")
print("=== regression verdict ===")
print(f"requests    : {summary['requestsTotal']} total, {summary['requestsFailed']} transport-failed")
print(f"verdict     : {verdict.get('verdict')} -- {m['pairs']} pairs, {m['failures']} mismatch"
      f" ({m['bodyFailures']} with body changes)"
      + (f", {m['baselineFailures']} baseline-known" if baseline_dir else " (no baseline: all count)"))
for p in new_failures:
    for c in p.get("bodyChanges") or []:
        print(f"  BODY {c.get('severity')}: {c.get('endpoint')} {c.get('location')}"
              f" {c.get('baseline')!r} -> {c.get('candidate')!r}")
for f_ in flips:
    print(f"  BUDGET FLIP: {f_['metric']} {f_['op']} {f_['value']}{f_['unit'] or ''} "
          f"(baseline {f_['baselineObserved']} pass -> current {f_['currentObserved']} fail)")
if not new_failures and not flips:
    print("no status or body regressions detected")
if not baseline_dir and m["bodyFailures"]:
    print("NOTE: without a --baseline every scored body change counts, including")
    print("NOTE: whatever churn the volatile heuristic does not cover. Establish")
    print("NOTE: a baseline replay and gate against it.")
print(f"replay dir  : {replay_out}")
print(f"verdict json: {replay_out}/replay-verdict.json")
print(f"summary     : {summary_json}")
print(f"digest      : {work_dir}/report.prompt.md")
sys.exit(exit_code)
PY

if [[ "$rc" -eq 3 ]]; then
  echo "FAIL: regression(s) detected (status or body)" >&2
elif [[ "$rc" -eq 4 ]]; then
  echo "FAIL: budget flip(s) detected" >&2
fi
exit "$rc"
