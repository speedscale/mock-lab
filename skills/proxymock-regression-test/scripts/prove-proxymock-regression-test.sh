#!/usr/bin/env bash
# Proves: a baseline replay of the committed recording passes clean, a second
# gated run against the same target reports no regression (the known moving-ID
# noise floor does not false-positive), a target that changes one endpoint's
# STATUS trips the gate (exit 3) with requests.failed still 0, a target that
# changes only a response BODY field trips it too (exit 3, status identical to
# the recording), and a pair that already failed in the baseline but now fails
# DIFFERENTLY stays masked (exit 0) with the masked-but-different advisory.
# Also pins the blueprint precondition: a blueprint in <recording>/blueprints/
# loads and its chains fire, --require-blueprint keeps the verdict on success
# and writes none on failure, and that raw exit 1 maps onto exit 2.
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
regress_script="$script_dir/proxymock-regression-test.sh"

need_cmd curl
need_cmd go
need_cmd proxymock
need_cmd python3
need_cmd lsof
[[ -x "$regress_script" ]] || die "regression-test script is not executable: $regress_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-regression-proof.$$"
pids=()
ports=()
trap ql_prove_cleanup EXIT
mkdir -p "$tmp"

app_port="$(ql_pick_port)"
out_port="$(ql_pick_port)"
health_port="$(ql_pick_port)"
status_port="$(ql_pick_port)"
body_port="$(ql_pick_port)"
masked_port="$(ql_pick_port)"
ports=("$app_port" "$out_port" "$health_port" "$status_port" "$body_port"
       "$masked_port")

echo "starting mock-lab Go app with downstream mocked from the recording"
( cd "$repo_root/go" && PORT="$app_port" \
    proxymock mock \
      --in "$recording" \
      --proxy-out-port "$out_port" \
      --health-port "$health_port" \
      -- go run . ) >"$tmp/mock.log" 2>&1 &
pids+=("$!")

ql_wait_url "http://127.0.0.1:${app_port}/" || die "app under proxymock mock did not start; see $tmp/mock.log"

echo "step 1: baseline replay (no baseline, no gate; expect exit 0)"
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${app_port}" \
  --work-dir "$tmp/base" >"$tmp/base.out" 2>&1 || {
    cat "$tmp/base.out" >&2
    die "baseline run exited nonzero"
  }
cat "$tmp/base.out"
[[ -s "$tmp/base/summary.json" ]] || die "baseline run did not write summary.json"
[[ -d "$tmp/base/replayed" ]] || die "baseline run did not write a replay dir"
for f in report.json report.html report.prompt.md; do
  [[ -s "$tmp/base/$f" ]] || die "baseline run did not write $f"
done

echo "step 2: gated rerun against the same target (expect exit 0: noise floor is not a regression)"
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${app_port}" \
  --baseline "$tmp/base/replayed" \
  --fail-on-regression \
  --work-dir "$tmp/same" >"$tmp/same.out" 2>&1 || {
    cat "$tmp/same.out" >&2
    die "gated rerun against an unchanged target should pass"
  }
cat "$tmp/same.out"

# Every stub below answers with the RECORDED status and body for each pair
# (see ql_write_recording_stub), so a seeded change is the ONLY difference the
# verdict can find. Each stub takes one override, and every HTTP exchange
# completes either way: requests.failed cannot see any of these.
ql_write_recording_stub "$tmp/stub.py"
python3 "$tmp/stub.py" "$status_port" "$recording" \
  '{"/api/stats": {"status": 404}}' &
pids+=("$!")
python3 "$tmp/stub.py" "$body_port" "$recording" \
  '{"/api/stats": {"replace": ["\"total\": 24", "\"total\": 25"]}}' &
pids+=("$!")
python3 "$tmp/stub.py" "$masked_port" "$recording" \
  '{"/api/orders": {"status": 500}}' &
pids+=("$!")
for p in "$status_port" "$body_port" "$masked_port"; do
  ql_wait_url "http://127.0.0.1:${p}/" || die "recorded-body stub on $p did not start"
done

echo "step 3: status regression (GET /api/stats now 404; expect exit 3)"
regress_rc=0
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${status_port}" \
  --baseline "$tmp/base/replayed" \
  --fail-on-regression \
  --work-dir "$tmp/regressed" >"$tmp/regressed.out" 2>&1 || regress_rc=$?
cat "$tmp/regressed.out"
[[ "$regress_rc" -eq 3 ]] || die "expected exit 3 (status regression), got $regress_rc"

python3 - "$tmp/regressed/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
new = s["match"]["newFailures"]
if not new:
    raise SystemExit("no new match failures recorded in summary.json")
stats = [p for p in new if (p.get("uri") or "").startswith("/api/stats")]
if not stats:
    raise SystemExit(f"/api/stats not among new failures: {new}")
if stats[0].get("observedStatus") != 404:
    raise SystemExit(f"expected observed 404 on /api/stats: {stats[0]}")
if s.get("requestsFailed") != 0:
    raise SystemExit(f"expected requests.failed == 0, got {s.get('requestsFailed')}")
print(f"PASS: {len(new)} new match failure(s), requests.failed=0, exit gate fired")
PY

echo "step 4: body-only regression (GET /api/stats total 24 -> 25; expect exit 3)"
# The status is IDENTICAL to the recording here. Before native body scoring this
# run scored verdict 'pass' with exit 0.
body_rc=0
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${body_port}" \
  --baseline "$tmp/base/replayed" \
  --fail-on-regression \
  --work-dir "$tmp/bodyregressed" >"$tmp/bodyregressed.out" 2>&1 || body_rc=$?
cat "$tmp/bodyregressed.out"
[[ "$body_rc" -eq 3 ]] || die "expected exit 3 (body-only regression), got $body_rc"

python3 - "$tmp/bodyregressed/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
stats = [p for p in s["match"]["newFailures"]
         if (p.get("uri") or "").startswith("/api/stats")]
if not stats:
    raise SystemExit(f"/api/stats not among new failures: {s['match']['newFailures']}")
p = stats[0]
if p["recordedStatus"] != p["observedStatus"]:
    raise SystemExit(f"status changed too, not a body-only case: {p}")
if p.get("bodyMatch") != "fail":
    raise SystemExit(f"expected bodyMatch fail: {p}")
changes = [c for c in p.get("bodyChanges") or []
           if c.get("kind") == "value_changed" and c.get("location", "").endswith("total")]
if not changes:
    raise SystemExit(f"no value_changed on total: {p.get('bodyChanges')}")
if (changes[0].get("baseline"), changes[0].get("candidate")) != ("24", "25"):
    raise SystemExit(f"unexpected change values: {changes[0]}")
if not s["match"]["bodyFailures"]:
    raise SystemExit("summary did not carry bodyFailures")
if s.get("requestsFailed") != 0:
    raise SystemExit(f"expected requests.failed == 0, got {s.get('requestsFailed')}")
print("PASS: body-only change caught with the status unchanged, requests.failed=0")
PY

echo "step 5: already-failing pair fails DIFFERENTLY (401 -> 500; expect exit 3)"
# /api/orders 401s in the baseline (no blueprint applied). This stub answers 500
# on the same pair: the pair was already a mismatch, so the question is whether
# baseline masking swallows the change. It does not -- measured on v2.5.812, a
# different observed status on an already-failing pair scores newMismatch true.
masked_rc=0
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${masked_port}" \
  --baseline "$tmp/base/replayed" \
  --fail-on-regression \
  --work-dir "$tmp/masked" >"$tmp/masked.out" 2>&1 || masked_rc=$?
cat "$tmp/masked.out"
[[ "$masked_rc" -eq 3 ]] || die "expected exit 3 (changed failure on a known-bad pair), got $masked_rc"
python3 - "$tmp/masked/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
orders = [p for p in s["match"]["newFailures"]
          if (p.get("uri") or "").startswith("/api/orders")]
if not orders:
    raise SystemExit(f"/api/orders not among new failures: {s['match']['newFailures']}")
if orders[0]["observedStatus"] != 500:
    raise SystemExit(f"expected observed 500: {orders[0]}")
print("PASS: a changed failure on a baseline-failing pair is not masked")
PY

echo "step 6: masked-but-different advisory fires on a masked pair that changed"
# Unit check of ql_advise_masked_different against fixture verdicts: masking is
# per-pair, so a pair carried as known-mismatch can be failing differently than
# it did in the baseline. The advisory is the only thing that says so.
mkdir -p "$tmp/adv-base"
cat >"$tmp/adv-base/replay-verdict.json" <<'JSON'
{"schemaVersion": 1, "pairs": [
  {"refUuid": "same", "method": "GET", "endpoint": "/api/orders", "match": "fail",
   "bodyMatch": "fail", "observedStatus": 401,
   "bodyChanges": [{"kind": "field_added", "location": "http.res.bodyBase64.error"}]},
  {"refUuid": "stable", "method": "GET", "endpoint": "/api/categories", "match": "fail",
   "bodyMatch": "pass", "observedStatus": 500, "bodyChanges": []}]}
JSON
cat >"$tmp/adv-cur.json" <<'JSON'
{"schemaVersion": 1, "pairs": [
  {"refUuid": "same", "method": "GET", "endpoint": "/api/orders", "match": "pass",
   "bodyMatch": "fail", "observedStatus": 200, "newMismatch": false,
   "classification": "known-mismatch",
   "bodyChanges": [{"kind": "value_changed", "location": "http.res.bodyBase64.total"}]},
  {"refUuid": "stable", "method": "GET", "endpoint": "/api/categories", "match": "fail",
   "bodyMatch": "pass", "observedStatus": 500, "newMismatch": false,
   "classification": "known-mismatch", "bodyChanges": []}]}
JSON
ql_advise_masked_different "$tmp/adv-cur.json" "$tmp/adv-base" >"$tmp/adv.out" 2>&1
cat "$tmp/adv.out"
grep -q "ADVISORY: masked but different: GET /api/orders" "$tmp/adv.out" \
  || die "step 6: advisory did not fire on the changed masked pair"
grep -q "/api/categories" "$tmp/adv.out" \
  && die "step 6: advisory fired on a pair failing identically"
echo "ok: advisory names only the pair whose failure changed"

echo "step 7: blueprint loading and --require-blueprint exit mapping"
# Pins the measured facts behind the blueprint precondition:
#   1. a blueprint in <recording>/blueprints/ loads AND its chains fire
#   2. --require-blueprint costs the verdict only on FAILURE: with the
#      blueprint loaded it exits 0 and still writes replay-verdict.json; with
#      an unresolvable name it exits 1 and writes none -- which is why this
#      skill measures smart_replace instead of gating on the flag, and when the
#      flag is used, ql_run_replay maps that raw 1 onto the caller's own
#      precondition code (2 here), never leaking it as 1
#
# What is deliberately NOT pinned: whether a blueprint in the workspace dir
# BESIDE the recording loads. It does in a real proxymock workspace (measured
# on mock-lab's own go/proxymock: same "Loaded blueprint" line, smart_replace
# present, orders 201->201), but not in scratch trees fabricated here, so
# asserting either way from this proof would encode a rule that does not hold.
#
# These replays target http://localhost:PORT, not 127.0.0.1 like the steps
# above. The committed blueprint filters on network_address CONTAINS
# "localhost", and replay rewrites the address to the target, so the same run
# against 127.0.0.1 loads the blueprint and fires NOTHING (measured: 2
# smart_replace files vs 0, everything else held constant).
src_bp="$repo_root/lab/proxymock/blueprints/mocklab-smart-replace.json"
[[ -s "$src_bp" ]] || die "step 7: missing committed blueprint: $src_bp"
bp_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$src_bp")"

# (a) control: nothing staged, so the name must not appear at all. Without it,
# (b) proves nothing -- the global ~/.speedscale blueprints load either way.
mkdir -p "$tmp/bp-none/recording"
cp -R "$recording"/. "$tmp/bp-none/recording/"
rm -rf "$tmp/bp-none/recording/blueprints"
proxymock replay --in "$tmp/bp-none/recording" \
  --test-against "http://localhost:${app_port}" \
  --out "$tmp/bp-none-out" --output json \
  >"$tmp/bp-none.json" 2>"$tmp/bp-none.log" || true
grep -q "Loaded blueprint \"$bp_name\"" "$tmp/bp-none.log" \
  && die "step 7a: control loaded a blueprint that was never staged"
[[ "$(ql_smart_replace_file_count "$tmp/bp-none-out")" -eq 0 ]] \
  || die "step 7a: control replay carries smart_replace with no blueprint staged"
echo "ok: control stages nothing, loads nothing, fires nothing"

# (b) inside the recording dir: loads and the chains RUN
mkdir -p "$tmp/bp-inside/recording"
cp -R "$recording"/. "$tmp/bp-inside/recording/"
mkdir -p "$tmp/bp-inside/recording/blueprints"
cp "$src_bp" "$tmp/bp-inside/recording/blueprints/"
proxymock replay --in "$tmp/bp-inside/recording" \
  --test-against "http://localhost:${app_port}" \
  --out "$tmp/bp-inside-out" --output json \
  >"$tmp/bp-inside.json" 2>"$tmp/bp-inside.log" || true
grep -q "Loaded blueprint \"$bp_name\"" "$tmp/bp-inside.log" \
  || die "step 7b: blueprint in <recording>/blueprints/ did not load; see $tmp/bp-inside.log"
[[ "$(ql_smart_replace_file_count "$tmp/bp-inside-out")" -gt 0 ]] \
  || die "step 7b: blueprint loaded but no smart_replace event fired"
[[ "$(ql_blueprint_count "$(ql_inner_blueprint_dir "$tmp/bp-inside/recording")")" -eq 1 ]] \
  || die "step 7b: ql_inner_blueprint_dir does not point at the loading path"
echo "ok: blueprint in <recording>/blueprints/ loads, chains fire, helper agrees"

# (c) --require-blueprint on a blueprint that DID load: exit 0, verdict written
req_rc=0
proxymock replay --in "$tmp/bp-inside/recording" \
  --test-against "http://localhost:${app_port}" \
  --out "$tmp/bp-req-out" --output json \
  --require-blueprint "$bp_name" \
  >"$tmp/bp-req.json" 2>"$tmp/bp-req.log" || req_rc=$?
[[ "$req_rc" -eq 0 ]] || die "step 7c: --require-blueprint on a loaded blueprint exited $req_rc"
[[ -s "$tmp/bp-req-out/replay-verdict.json" ]] \
  || die "step 7c: --require-blueprint suppressed the verdict on success"
echo "ok: --require-blueprint exits 0 and keeps the verdict when the blueprint ran"

# (d) --require-blueprint on a name that never loaded: exit 1, NO verdict
bogus_rc=0
proxymock replay --in "$tmp/bp-inside/recording" \
  --test-against "http://127.0.0.1:${app_port}" \
  --out "$tmp/bp-bogus-out" --output json \
  --require-blueprint "does-not-exist" \
  >"$tmp/bp-bogus.json" 2>"$tmp/bp-bogus.log" || bogus_rc=$?
[[ "$bogus_rc" -eq 1 ]] || die "step 7d: expected raw exit 1 from --require-blueprint, got $bogus_rc"
[[ ! -s "$tmp/bp-bogus-out/replay-verdict.json" ]] \
  || die "step 7d: --require-blueprint wrote a verdict on failure; it could now be a gate"
echo "ok: --require-blueprint exits 1 and writes no replay-verdict.json"

# (e) that raw 1 is mapped onto this skill's precondition code, not leaked
mapped_rc=0
( ql_run_replay proxymock "$tmp/bp-inside/recording" \
    "http://127.0.0.1:${app_port}" "$tmp/bp-mapped-out" \
    "$tmp/bp-mapped.json" "$tmp/bp-mapped.log" 2 \
    --require-blueprint "does-not-exist" ) >/dev/null 2>&1 || mapped_rc=$?
[[ "$mapped_rc" -eq 2 ]] \
  || die "step 7e: replay exit 1 must map to the skill's precondition code 2, got $mapped_rc"
echo "ok: replay exit 1 maps to precondition exit 2, never leaked as 1"

echo "PASS: baseline clean, noise floor stable, status regression (3), body-only regression (3), changed failure not masked (3), advisory unit check, blueprint load path + require-blueprint mapping"
