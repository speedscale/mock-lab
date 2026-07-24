#!/usr/bin/env bash
# Proves: every scenario builds a chaos variant of the committed recording
# that the mock verifiably loads, flaky serves an EXACT deterministic F/N
# fault ratio (verified via direct proxy curls), slow injects at least the
# configured per-endpoint latency, restore swaps the healthy recording back,
# a bogus --target exits 2, and an edit that breaks an RRPair (the documented
# 'failed to parse response line' failure mode) is caught by validation with
# exit 3.
set -euo pipefail

# shared ql_* helpers; a copied skill needs skills/lib/common.sh too
if [[ ! -r "$(dirname "$0")/../../lib/common.sh" ]]; then
  echo "FAIL: missing $(dirname "$0")/../../lib/common.sh (copy skills/lib/common.sh alongside this skill)" >&2
  exit 1
fi
source "$(dirname "$0")/../../lib/common.sh"

die() { ql_fail "$@"; }
need_cmd() { ql_prove_need_cmd "$1"; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$skill_dir/../.." && pwd)"
chaos_script="$script_dir/proxymock-chaos-mock.sh"

need_cmd curl
need_cmd proxymock
need_cmd python3
need_cmd lsof
[[ -x "$chaos_script" ]] || die "chaos script is not executable: $chaos_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-chaos-proof.$$"
pids=()
ports=()
# --serve backgrounds a mock the script does not own; ql_prove_cleanup sweeps
# our ports so nothing this proof started outlives it
trap ql_prove_cleanup EXIT
mkdir -p "$tmp"

# every recorded downstream URI, reachable through the mock's proxy port with
# a direct proxy curl (plain http scheme; the mock matches on signature)
downstream="http://demo-api.trafficreplay.com"

proxy_curl() {
  # proxy_curl PORT PATH -> status code
  curl -s -o /dev/null -m 10 -w '%{http_code}' \
    -x "http://127.0.0.1:$1" "${downstream}$2"
}

echo "step 1: build + validate a variant for every scenario (expect exit 0)"
for scenario in down ratelimit garbage flaky slow; do
  args=(--in "$recording" --scenario "$scenario" --work-dir "$tmp/$scenario")
  case "$scenario" in
    slow) args+=(--target '^/v1/categories' --latency 500ms) ;;
    flaky) args+=(--target '^/v1/categories' --ratio 1/2) ;;
    ratelimit) args+=(--target '^/v1/projects' --retry-after 30) ;;
    *) args+=(--target '^/v1/projects') ;;
  esac
  "$chaos_script" "${args[@]}" >"$tmp/$scenario.out" 2>&1 || {
    cat "$tmp/$scenario.out" >&2
    die "scenario $scenario did not build (expected exit 0)"
  }
  [[ -s "$tmp/$scenario/manifest.json" ]] || die "$scenario: no manifest.json"
  [[ -d "$tmp/$scenario/chaos-recording" ]] || die "$scenario: no variant dir"
  python3 - "$tmp/$scenario/manifest.json" "$scenario" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
scenario = sys.argv[2]
assert m["scenario"] == scenario, m["scenario"]
assert m["validation"] and m["validation"]["loaded"], "variant did not validate"
assert m["matched"], "no matched pairs"
if scenario != "slow":
    assert m["edits"], "no edits recorded"
    assert all(e["original"] is not None or e["action"] == "duplicate"
               for e in m["edits"])
print(f"  {scenario}: validated, {len(m['edits'])} edit(s), "
      f"{len(m['matched'])} matched pair(s)")
PY
done
# the source recording must be untouched (git-clean check on the committed dir)
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse >/dev/null 2>&1; then
  dirty="$(git -C "$repo_root" status --porcelain -- lab/proxymock/recording)"
  [[ -z "$dirty" ]] || die "source recording was modified: $dirty"
fi
echo "  source recording untouched"

echo "step 2: flaky serves an exact deterministic 1/2 ratio (direct proxy curls)"
flaky_port="$(ql_pick_port)"
flaky_health="$(ql_pick_port)"
ports+=("$flaky_port" "$flaky_health")
rm -rf "$tmp/flaky-serve"
"$chaos_script" --in "$recording" --scenario flaky --target '^/v1/categories' \
  --ratio 1/2 --work-dir "$tmp/flaky-serve" --serve \
  --proxy-out-port "$flaky_port" --health-port "$flaky_health" \
  >"$tmp/flaky-serve.out" 2>&1 || {
    cat "$tmp/flaky-serve.out" >&2
    die "flaky --serve failed"
  }
seq_got=""
for i in 1 2 3 4 5 6; do
  seq_got+="$(proxy_curl "$flaky_port" /v1/categories) "
done
[[ "$seq_got" == "503 200 503 200 503 200 " ]] \
  || die "flaky ratio not deterministic 1/2: got '$seq_got'"
# an untargeted endpoint stays healthy through the same chaos mock
[[ "$(proxy_curl "$flaky_port" /v1/projects)" == "200" ]] \
  || die "untargeted endpoint was not healthy under flaky"
echo "  exact 1/2 alternation confirmed: $seq_got"

echo "step 3: restore swaps the healthy recording back on the same port"
"$chaos_script" --restore --work-dir "$tmp/flaky-serve" \
  >"$tmp/restore.out" 2>&1 || {
    cat "$tmp/restore.out" >&2
    die "--restore failed"
  }
for i in 1 2 3; do
  [[ "$(proxy_curl "$flaky_port" /v1/categories)" == "200" ]] \
    || die "restored mock still serving faults"
done
echo "  healthy 200s after restore"
ql_sweep_port "$flaky_port"

echo "step 4: slow injects at least the configured per-endpoint latency"
slow_port="$(ql_pick_port)"
slow_health="$(ql_pick_port)"
ports+=("$slow_port" "$slow_health")
rm -rf "$tmp/slow-serve"
"$chaos_script" --in "$recording" --scenario slow --target '^/v1/categories' \
  --latency 500ms --work-dir "$tmp/slow-serve" --serve \
  --proxy-out-port "$slow_port" --health-port "$slow_health" \
  >"$tmp/slow-serve.out" 2>&1 || {
    cat "$tmp/slow-serve.out" >&2
    die "slow --serve failed"
  }
t="$(curl -s -o /dev/null -m 10 -w '%{time_total}' \
  -x "http://127.0.0.1:${slow_port}" "${downstream}/v1/categories")"
python3 - "$t" <<'PY'
import sys
t = float(sys.argv[1])
assert t >= 0.5, f"observed latency {t}s < configured 0.5s"
print(f"  target endpoint took {t:.3f}s (>= 0.500s configured)")
PY
ql_sweep_port "$slow_port"

echo "step 5: bogus --target exits 2"
rc=0
"$chaos_script" --in "$recording" --scenario down \
  --target '^/no/such/endpoint' --work-dir "$tmp/bogus" \
  >"$tmp/bogus.out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { cat "$tmp/bogus.out" >&2; die "expected exit 2, got $rc"; }
grep -q 'matched no outbound' "$tmp/bogus.out" || die "exit 2 without the target-not-found message"
echo "  exit 2 with the outbound endpoint list"

echo "step 6: a broken edit fails validation with exit 3"
rc=0
CHAOS_FORCE_BAD_EDIT=1 "$chaos_script" --in "$recording" --scenario down \
  --target '^/v1/projects' --work-dir "$tmp/broken" \
  >"$tmp/broken.out" 2>&1 || rc=$?
[[ "$rc" -eq 3 ]] || { cat "$tmp/broken.out" >&2; die "expected exit 3, got $rc"; }
grep -q 'will not load' "$tmp/broken.out" || die "exit 3 without the validation message"
grep -q 'failed to parse response line' "$tmp/broken/validate.log" \
  || die "validate.log does not show the documented parse failure"
python3 - "$tmp/broken/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["validation"] and m["validation"]["loaded"] is False
print("  exit 3, manifest records validation.loaded=false, parse error in log")
PY

echo "PASS: all scenarios validated, flaky ratio exact, slow latency observed, restore clean, exits 2/3 proven"
