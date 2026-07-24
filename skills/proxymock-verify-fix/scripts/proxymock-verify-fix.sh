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
  proxymock-verify-fix.sh --in DIR --test-against URL [options]

Verify a bug fix by replaying the incident traffic capture against the fixed
build. The incident recording contains the FAILING responses (e.g. 500s) as
recorded truth, so the pass/fail semantics invert: a match failure of the form
"recorded 500 -> observed 200" on the incident endpoint is the FIX SIGNAL, and
a run where every pair matches means the bug STILL REPRODUCES (the buggy
behavior equals the recording). requests.failed cannot see any of this: a
status change still completes the HTTP exchange, so the fix appears only in
the per-RRPair verdict. The partition and its exit codes come from replay
--verify-fix, read back from <out>/replay-verdict.json.

That verdict is STATUS-ONLY (measured on v2.5.805: a body-only collateral
regression alongside a real fix still scores "fix-confirmed" and exits 0). It
is necessary but NOT sufficient: diff bodies with the proxymock MCP tool
response_diff, against the noise allowlist, before accepting the fix.

Required:
  --in DIR              Incident recording directory (RRPair files captured
                        while the bug manifested)
  --test-against URL    The build to verify (e.g. http://localhost:8080)

Options:
  --expect PATTERN      Regex matched against the request URI naming the
                        incident endpoint(s). Without it the incident set is
                        auto-detected: every pair whose RECORDED response has
                        an error status (>= 400).
  --baseline DIR        Replay output dir from a run against the BUGGY build
                        (e.g. a --reproduce run's replayed dir). Non-incident
                        mismatches already present there are environment noise,
                        not collateral, unless --fail-on-collateral is set.
  --fail-on-collateral  Escalate: count baseline-known non-incident mismatches
                        as collateral too. New collateral is always fatal.
  --mocks DIR           Healthy recording dir whose outbound pairs fill the
                        downstream gap (incident captures usually lack the
                        fixed path's downstream traffic). The script prints
                        the union mock command; proxymock mock accepts
                        repeated --in flags, no combined dir needed.
  --reproduce           Run BEFORE fixing: replay against the buggy build
                        --runs N times (default 3) and assert the incident
                        reproduces with identical match outcomes every run.
  --runs N              Replay count for --reproduce (default 3)
  --work-dir DIR        Where to write replay output and the summary
                        (default: timestamped dir)
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

Exit codes:
  0  fix confirmed and no collateral (or --reproduce: the incident reproduces
     deterministically)
  2  fix NOT confirmed: incident endpoints still return the recorded error
     ("bug reproduces; fix not present"), or --reproduce found the capture
     does not reproduce / is unstable
  3  collateral regression detected (with or without the fix): a pair whose
     recording succeeded now observes something different
  4  precondition failure (bad args, missing dirs, no incident endpoints,
     replay did not run)

Output files (in --work-dir):
  replayed/ (or run-N/replayed/)  replay output RRPairs
  replayed/replay-verdict.json    proxymock's native per-pair verdict
  result.json (or run-N/result.json)  replay metrics
  summary.json                    machine-readable verdict with reproduced,
                                  fixed, and collateral lists (recorded and
                                  observed statuses plus file paths)

Examples:
  # before fixing: confirm the capture is a deterministic reproduction
  proxymock-verify-fix.sh --in ./incident/recording \
    --test-against http://localhost:8080 --reproduce

  # after fixing: prove the fix with the same capture
  proxymock-verify-fix.sh --in ./incident/recording \
    --test-against http://localhost:8080 --expect '^/api/stats' \
    --baseline ./reproduce-work/run-1/replayed
USAGE
}

# precondition failures use exit 4 per the output contract
die() { ql_die 4 "$@"; }
need_cmd() { ql_need_cmd "$1" 4; }

in_dir=""
target=""
expect=""
baseline_dir=""
mocks_dir=""
work_dir=""
fail_on_collateral="0"
reproduce="0"
runs="3"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --test-against) [[ $# -ge 2 ]] || die "--test-against requires a value"; target="$2"; shift 2 ;;
    --expect) [[ $# -ge 2 ]] || die "--expect requires a value"; expect="$2"; shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || die "--baseline requires a value"; baseline_dir="$2"; shift 2 ;;
    --mocks) [[ $# -ge 2 ]] || die "--mocks requires a value"; mocks_dir="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --fail-on-collateral) fail_on_collateral="1"; shift ;;
    --reproduce) reproduce="1"; shift ;;
    --runs) [[ $# -ge 2 ]] || die "--runs requires a value"; runs="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$target" ]] || die "--test-against is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
[[ -z "$baseline_dir" || -d "$baseline_dir" ]] || die "--baseline is not a directory: $baseline_dir"
[[ -z "$mocks_dir" || -d "$mocks_dir" ]] || die "--mocks is not a directory: $mocks_dir"
[[ "$runs" =~ ^[1-9][0-9]*$ ]] || die "--runs must be a positive integer: $runs"

need_cmd python3
ql_check_proxymock_bin "$proxymock_bin" 4

in_dir="$(ql_abs_path "$in_dir")"
[[ -n "$baseline_dir" ]] && baseline_dir="$(ql_abs_path "$baseline_dir")"
[[ -n "$mocks_dir" ]] && mocks_dir="$(ql_abs_path "$mocks_dir")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-verify-fix-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(ql_abs_path "$work_dir")"
summary_json="$work_dir/summary.json"

# --- precondition: blueprint anchoring ---------------------------------------
# Blueprints are loaded only from the --in path's parent proxymock directory's
# blueprints/ subdir, not from cwd and not from the output workspace (same
# anchoring rule as replay's own --out, which "anchors to the --in workspace,
# not the current directory"). Without a blueprint, endpoints that chain
# moving IDs replay with stale recorded values and fail for reasons unrelated
# to the fix, polluting the collateral list.
bp_dir="$(ql_blueprint_dir "$in_dir")"
bp_count="$(ql_blueprint_count "$bp_dir")"
if [[ "$bp_count" -eq 0 ]]; then
  echo "WARNING: no blueprints found at $bp_dir" >&2
  echo "WARNING: moving-ID endpoints (auth tokens, created ids) may fail replay" >&2
  echo "WARNING: for reasons unrelated to the fix and show up as collateral." >&2
else
  echo "blueprints: $bp_count file(s) in $bp_dir"
fi

# --- precondition: the incident capture's downstream gap ---------------------
# An incident capture systematically LACKS the fixed code path's downstream
# traffic: the buggy handler usually errored BEFORE calling its dependencies,
# so no outbound pair for that call was ever recorded. When the fixed build
# runs with its downstream mocked from the incident capture alone, the new
# downstream call has no mock: it is passed through to the live dependency
# (needs network) or returns 502 when air-gapped, and either can masquerade
# as "fix not confirmed" or collateral. proxymock mock accepts repeated --in
# flags (verified: mocks from both dirs serve), so union the incident capture
# with a healthy recording via --mocks.
has_outbound="0"
if ql_has_outbound "$in_dir"; then
  has_outbound="1"
fi
if [[ -n "$mocks_dir" ]]; then
  echo "mock union: serve the fixed build's downstream from BOTH recordings:"
  echo "  $proxymock_bin mock --in $in_dir --in $mocks_dir -- <your app>"
elif [[ "$has_outbound" == "1" ]]; then
  echo "WARNING: incident recording contains outbound pairs but no --mocks was" >&2
  echo "WARNING: given. The fixed code path's downstream calls are usually ABSENT" >&2
  echo "WARNING: from an incident capture (the buggy handler errored before" >&2
  echo "WARNING: calling them). If the target's downstream is mocked from this" >&2
  echo "WARNING: capture alone, expect live passthrough (needs network) or 502s" >&2
  echo "WARNING: when air-gapped. Supply --mocks <healthy recording dir>." >&2
fi

run_replay() {
  # run_replay OUT_DIR RESULT_JSON LOG_FILE [EXTRA_REPLAY_FLAG...]: replay the
  # incident capture in proxymock's native --verify-fix mode, which owns the
  # recorded-error partition and the 0/2/3 exit mapping
  local out="$1" result="$2" log="$3"
  shift 3
  ql_check_replay_out_empty "$out" 4
  ql_run_replay "$proxymock_bin" "$in_dir" "$target" "$out" "$result" "$log" 4 \
    --verify-fix "$@"
  ql_echo_replay_verdict_lines "$log"
  # The console blueprint line lies (see ql_smart_replace_file_count); only
  # smart_replace events in the replay output prove a blueprint applied.
  if [[ "$bp_count" -gt 0 ]]; then
    local sr_files
    sr_files="$(ql_smart_replace_file_count "$out")"
    if [[ "$sr_files" -eq 0 ]]; then
      echo "WARNING: blueprint(s) present but no smart_replace events in $out;" >&2
      echo "WARNING: the blueprint did not demonstrably apply to this replay." >&2
    fi
  fi
}

rc=0
if [[ "$reproduce" == "1" ]]; then
  # No native equivalent: -n/--times replays repeatedly but never compares the
  # runs, so per-run stability is still computed here from each run's verdict.
  run_dirs=()
  expect_flags=()
  [[ -n "$expect" ]] && expect_flags+=(--expect "$expect")
  for i in $(seq 1 "$runs"); do
    run_dir="$work_dir/run-$i"
    mkdir -p "$run_dir"
    echo "reproduce run $i/$runs: $in_dir -> $target"
    run_replay "$run_dir/replayed" "$run_dir/result.json" "$run_dir/replay.log" \
      ${expect_flags[@]+"${expect_flags[@]}"}
    run_dirs+=("$run_dir/replayed")
  done
  python3 - "$in_dir" "$summary_json" "$expect" "${run_dirs[@]}" <<'PY' || rc=$?
import json, pathlib, sys

in_dir, summary_json, expect = sys.argv[1:4]
run_dirs = sys.argv[4:]

def row(p):
    return {
        "refUuid": p.get("refUuid"),
        "method": p.get("method"),
        "uri": p.get("endpoint"),
        "recordedStatus": p.get("recordedStatus"),
        "observedStatus": p.get("observedStatus"),
        "sourceFile": p.get("sourceFile"),
        "replayFile": p.get("replayFile"),
    }

runs, outcome_maps, incident_counts = [], [], []
for run_dir in run_dirs:
    verdict = json.load(open(pathlib.Path(run_dir) / "replay-verdict.json"))
    pairs = verdict.get("pairs") or []
    reproduced = [p for p in pairs if p.get("classification") == "bug-reproduced"]
    fixed = [p for p in pairs if p.get("classification") == "fix-confirmed"]
    other = [p for p in pairs
             if p.get("match") != "pass"
             and p.get("classification") not in ("bug-reproduced", "fix-confirmed")]
    incident_counts.append(len(reproduced) + len(fixed))
    # stability is judged on the whole scored set, not just the incident pairs
    outcome_maps.append({p.get("refUuid"): (p.get("match"), p.get("classification"))
                         for p in pairs})
    runs.append({
        "replayDir": run_dir,
        "incidentReproduced": len(reproduced),
        "incidentNotReproduced": len(fixed),
        "otherMismatches": len(other),
        "notReproduced": [row(p) for p in fixed],
    })

deterministic = all(m == outcome_maps[0] for m in outcome_maps[1:])
reproduces = all(r["incidentReproduced"] > 0 and r["incidentNotReproduced"] == 0
                 for r in runs)

exit_code = 0 if (deterministic and reproduces) else 2
summary = {
    "mode": "reproduce",
    "verdict": "reproduces" if exit_code == 0 else "does-not-reproduce",
    "incidentRecording": in_dir,
    "expect": expect or None,
    "incidentEndpoints": incident_counts[0] if incident_counts else 0,
    "runs": runs,
    "deterministic": deterministic,
    "exitCode": exit_code,
}
with open(summary_json, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

print("")
print("=== reproduction verdict ===")
print(f"incident set : {summary['incidentEndpoints']} recorded-error pair(s)"
      + (f" matching --expect {expect}" if expect else " (auto-detected)"))
for i, r in enumerate(runs, 1):
    print(f"  run {i}      : {r['incidentReproduced']}/{summary['incidentEndpoints']} "
          f"incident pair(s) reproduced, {r['otherMismatches']} other mismatch(es)")
if exit_code == 0:
    print(f"deterministic reproduction confirmed across {len(runs)} run(s)")
elif not reproduces:
    print("the incident did NOT reproduce: incident endpoints returned "
          "something other than the recorded error")
else:
    print("match outcomes differed between runs: the capture is not a "
          "deterministic reproduction")
print(f"summary      : {summary_json}")
sys.exit(exit_code)
PY
else
  echo "replaying incident recording: $in_dir -> $target"
  vf_flags=()
  [[ -n "$expect" ]] && vf_flags+=(--expect "$expect")
  [[ -n "$baseline_dir" ]] && vf_flags+=(--baseline "$baseline_dir")
  run_replay "$work_dir/replayed" "$work_dir/result.json" "$work_dir/replay.log" \
    ${vf_flags[@]+"${vf_flags[@]}"}
  python3 - "$in_dir" "$work_dir/replayed" "$baseline_dir" "$work_dir/result.json" \
    "$summary_json" "$expect" "$fail_on_collateral" "$ql_replay_rc" <<'PY' || rc=$?
import json, pathlib, sys

(in_dir, replay_out, baseline_dir, result_json, summary_json, expect,
 fail_on_collateral, replay_rc) = sys.argv[1:9]
fail_on_collateral = fail_on_collateral == "1"
replay_rc = int(replay_rc)

# --verify-fix owns the partition: it classifies each pair as fix-confirmed,
# bug-reproduced, collateral (new) or known-mismatch (also failed in
# --baseline), and maps that onto exit 0 / 2 / 3
verdict = json.load(open(pathlib.Path(replay_out) / "replay-verdict.json"))
pairs = verdict.get("pairs") or []

def rows(classification):
    return [{
        "refUuid": p.get("refUuid"),
        "method": p.get("method"),
        "uri": p.get("endpoint"),
        "recordedStatus": p.get("recordedStatus"),
        "observedStatus": p.get("observedStatus"),
        "sourceFile": p.get("sourceFile"),
        "replayFile": p.get("replayFile"),
    } for p in pairs if p.get("classification") == classification]

fixed = rows("fix-confirmed")
reproduced = rows("bug-reproduced")
collateral_new = rows("collateral")
collateral_known = rows("known-mismatch")

# native exit codes already match this script's contract (2 bug reproduces,
# 3 collateral); only --fail-on-collateral escalates beyond them
exit_code = replay_rc
if fail_on_collateral and collateral_known:
    exit_code = 3

result = json.load(open(result_json))
overall = next((e for e in result.get("endpoints", []) if e.get("url") == "-ALL-"), {})
metrics = overall.get("metrics", {})

verdict_name = ("collateral" if exit_code == 3
                else "not-fixed" if exit_code == 2 else "fixed")
summary = {
    "mode": "verify",
    "verdict": verdict_name,
    "incidentRecording": in_dir,
    "replayDir": replay_out,
    "baselineDir": baseline_dir or None,
    "expect": expect or None,
    "incidentEndpoints": len(fixed) + len(reproduced),
    "requestsTotal": metrics.get("requests.total"),
    "requestsFailed": metrics.get("requests.failed"),
    "fixed": fixed,
    "reproduced": reproduced,
    # the native verdict scores only pairs that were actually replayed, so an
    # incident pair with no replay outcome is not reported; a nonzero
    # requests.failed is the signal that one went missing
    "unreplayedIncident": [],
    "collateral": {"new": collateral_new, "baselineKnown": collateral_known},
    "failOnCollateral": fail_on_collateral,
    "exitCode": exit_code,
}
with open(summary_json, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")

print("")
print("=== fix verification verdict ===")
print(f"incident set : {summary['incidentEndpoints']} recorded-error pair(s)"
      + (f" matching --expect {expect}" if expect else " (auto-detected)"))
print(f"requests     : {metrics.get('requests.total')} total, "
      f"{metrics.get('requests.failed')} transport-failed")
if metrics.get("requests.failed"):
    print("WARNING: transport failures present; an incident pair that never "
          "replayed is invisible to the verdict", file=sys.stderr)
for r in collateral_known:
    print(f"  known noise: {r['method']} {r['uri']} "
          f"recorded {r['recordedStatus']} -> observed {r['observedStatus']}"
          " (also failed in baseline)")
if verdict_name == "fixed":
    print("fix confirmed: incident endpoints no longer return the recorded error")
elif verdict_name == "not-fixed":
    print("bug reproduces; fix not present (incident endpoints still return "
          "the recorded error)")
else:
    print("collateral regression: a recorded-success pair changed behavior")
print("STATUS-LEVEL GATING ONLY: a body-only regression scores 'fix-confirmed'")
print("here. Body-level diffing with the MCP tool response_diff (against the")
print("noise allowlist) is REQUIRED before accepting the fix.")
print(f"replay dir   : {replay_out}")
print(f"verdict json : {replay_out}/replay-verdict.json")
print(f"summary      : {summary_json}")
sys.exit(exit_code)
PY
fi

if [[ "$rc" -eq 2 && "$reproduce" == "1" ]]; then
  echo "FAIL: the capture is not a deterministic reproduction" >&2
elif [[ "$rc" -eq 2 ]]; then
  echo "FAIL: fix not confirmed" >&2
elif [[ "$rc" -eq 3 ]]; then
  echo "FAIL: collateral regression detected" >&2
fi
exit "$rc"
