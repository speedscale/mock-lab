#!/usr/bin/env bash
# Proves the semantic inversion end to end, hermetically (no cloud, no live
# downstream, no app build). It fabricates an incident recording by flipping
# one GET pair's recorded status to 500 in a copy of the committed recording,
# then drives the verify script through four sub-cases against stub targets:
#   a) --reproduce vs a buggy stub (500 on the incident path)  -> exit 0
#   b) verify vs a fixed stub (recorded statuses everywhere)   -> exit 0
#   c) verify vs the buggy stub (all pairs match)              -> exit 2
#   d) verify vs a stub with a second, unrelated discrepancy   -> exit 3
#   e) verify vs a stub whose collateral is BODY-only          -> exit 3
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
verify_script="$script_dir/proxymock-verify-fix.sh"

need_cmd curl
need_cmd proxymock
need_cmd python3
need_cmd lsof
[[ -x "$verify_script" ]] || die "verify script is not executable: $verify_script"

recording="$repo_root/lab/proxymock/recording"
blueprints="$repo_root/lab/proxymock/blueprints"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-verify-fix-proof.$$"
pids=()
ports=()
trap ql_prove_cleanup EXIT
mkdir -p "$tmp"

# --- fabricate the incident recording ----------------------------------------
# Copy the committed recording into its own workspace and flip GET /api/stats
# from 200 to 500: the incident capture stores the FAILING response as recorded
# truth. The blueprint is staged INSIDE the recording dir, which is where replay
# loads it from when --in is that dir; a copy beside the recording never loads.
echo "fabricating incident recording (GET /api/stats recorded 500)"
mkdir -p "$tmp/incident"
cp -R "$recording" "$tmp/incident/recording"
if [[ -d "$blueprints" ]]; then
  mkdir -p "$tmp/incident/recording/blueprints"
  cp "$blueprints"/*.json "$tmp/incident/recording/blueprints/"
fi

incident_file="$(grep -l '"uri":"/api/stats"' "$tmp/incident/recording/localhost"/*.md | head -1)"
[[ -n "$incident_file" ]] || die "could not find the GET /api/stats pair in the recording"

# rewrite the recorded status in every representation the RRPair carries:
# the visible RESPONSE block and the INTERNAL json (status, statusCode,
# statusMessage) must agree or replay may read the stale value
python3 - "$incident_file" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
subs = [
    ("HTTP/1.1 200 OK", "HTTP/1.1 500 Internal Server Error"),
    ('"status":"200"', '"status":"500"'),
    ('"statusCode":200,"statusMessage":"200 OK"',
     '"statusCode":500,"statusMessage":"500 Internal Server Error"'),
]
for old, new in subs:
    if old not in text:
        raise SystemExit(f"expected marker not found in {path}: {old}")
    text = text.replace(old, new, 1)
open(path, "w").write(text)
print(f"seeded 500 into {path}")
PY
incident="$tmp/incident/recording"

# --- stub targets ------------------------------------------------------------
# Every stub answers with the incident recording's own status AND body for each
# pair (see ql_write_recording_stub), so all HTTP exchanges complete
# (requests.failed stays 0) and the only differences are the seeded ones. The
# buggy stub needs no override: the incident recording already carries the 500.
ql_write_recording_stub "$tmp/stub.py"

buggy_port="$(ql_pick_port)"       # stats 500 as recorded: the bug still present
fixed_port="$(ql_pick_port)"       # stats 200: the fix
collateral_port="$(ql_pick_port)"  # stats 200 but categories 404: fix plus collateral
bodycol_port="$(ql_pick_port)"     # stats 200 and a categories BODY change only
ports=("$buggy_port" "$fixed_port" "$collateral_port" "$bodycol_port")

python3 "$tmp/stub.py" "$buggy_port" "$incident" &
pids+=("$!")
python3 "$tmp/stub.py" "$fixed_port" "$incident" \
  '{"/api/stats": {"status": 200}}' &
pids+=("$!")
python3 "$tmp/stub.py" "$collateral_port" "$incident" \
  '{"/api/stats": {"status": 200}, "/api/categories": {"status": 404}}' &
pids+=("$!")
python3 "$tmp/stub.py" "$bodycol_port" "$incident" \
  '{"/api/stats": {"status": 200}, "/api/categories": {"replace": ["Database", "Datastore"]}}' &
pids+=("$!")
for p in "$buggy_port" "$fixed_port" "$collateral_port" "$bodycol_port"; do
  ql_wait_url "http://127.0.0.1:${p}/" || die "recorded-body stub on $p did not start"
done

# --- case a: --reproduce against the buggy build (expect exit 0) -------------
echo "case a: --reproduce vs buggy stub (incident reproduces deterministically)"
"$verify_script" \
  --in "$incident" \
  --test-against "http://127.0.0.1:${buggy_port}" \
  --reproduce --runs 3 \
  --work-dir "$tmp/reproduce" >"$tmp/reproduce.out" 2>&1 || {
    cat "$tmp/reproduce.out" >&2
    die "case a: reproduce run should exit 0"
  }
cat "$tmp/reproduce.out"
grep -q "deterministic reproduction confirmed across 3 run(s)" "$tmp/reproduce.out" \
  || die "case a: missing deterministic-reproduction verdict"
[[ -s "$tmp/reproduce/summary.json" ]] || die "case a: no summary.json"

# --- case b: verify against the fixed build (expect exit 0) ------------------
echo "case b: verify vs fixed stub (recorded 500 -> observed 200 is the fix signal)"
"$verify_script" \
  --in "$incident" \
  --test-against "http://127.0.0.1:${fixed_port}" \
  --expect '^/api/stats' \
  --baseline "$tmp/reproduce/run-1/replayed" \
  --work-dir "$tmp/fixed" >"$tmp/fixed.out" 2>&1 || {
    cat "$tmp/fixed.out" >&2
    die "case b: verify against the fixed build should exit 0"
  }
cat "$tmp/fixed.out"
python3 - "$tmp/fixed/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "fixed", s["verdict"]
fixed = s["fixed"]
assert len(fixed) == 1, fixed
f = fixed[0]
assert (f["uri"] or "").startswith("/api/stats"), f
assert f["recordedStatus"] == 500 and f["observedStatus"] == 200, f
assert not s["reproduced"] and not s["collateral"]["new"], s
# the status flip completed the HTTP exchange: invisible to requests.failed
assert s["requestsFailed"] == 0, s["requestsFailed"]
print("PASS: fix confirmed via match tags, requests.failed=0")
PY

# --- case c: verify against the still-buggy build (expect exit 2) ------------
echo "case c: verify vs buggy stub (all pairs match means the bug reproduces)"
rc=0
"$verify_script" \
  --in "$incident" \
  --test-against "http://127.0.0.1:${buggy_port}" \
  --work-dir "$tmp/unfixed" >"$tmp/unfixed.out" 2>&1 || rc=$?
cat "$tmp/unfixed.out"
[[ "$rc" -eq 2 ]] || die "case c: expected exit 2 (bug still present), got $rc"
grep -q "bug reproduces; fix not present" "$tmp/unfixed.out" \
  || die "case c: missing 'bug reproduces; fix not present' message"

# --- case d: verify with a second discrepancy (expect exit 3) ----------------
echo "case d: verify vs collateral stub (fix present but /api/categories 404)"
rc=0
"$verify_script" \
  --in "$incident" \
  --test-against "http://127.0.0.1:${collateral_port}" \
  --work-dir "$tmp/collateral" >"$tmp/collateral.out" 2>&1 || rc=$?
cat "$tmp/collateral.out"
[[ "$rc" -eq 3 ]] || die "case d: expected exit 3 (collateral regression), got $rc"
python3 - "$tmp/collateral/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "collateral", s["verdict"]
new = s["collateral"]["new"]
assert any((r["uri"] or "").startswith("/api/categories") for r in new), new
# the fix signal is still visible alongside the collateral
assert any((r["uri"] or "").startswith("/api/stats") for r in s["fixed"]), s["fixed"]
print("PASS: collateral on /api/categories caught, fix signal still reported")
PY

# --- case e: collateral that is BODY-only (expect exit 3) --------------------
# /api/categories keeps its recorded 200 and changes one field. Before native
# body scoring this run reported 'fix-confirmed' and exited 0.
echo "case e: verify vs body-collateral stub (categories 200 but a changed field)"
rc=0
"$verify_script" \
  --in "$incident" \
  --test-against "http://127.0.0.1:${bodycol_port}" \
  --work-dir "$tmp/bodycollateral" >"$tmp/bodycollateral.out" 2>&1 || rc=$?
cat "$tmp/bodycollateral.out"
[[ "$rc" -eq 3 ]] || die "case e: expected exit 3 (body-only collateral), got $rc"
python3 - "$tmp/bodycollateral/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["verdict"] == "collateral", s["verdict"]
cats = [r for r in s["collateral"]["new"]
        if (r["uri"] or "").startswith("/api/categories")]
assert cats, s["collateral"]["new"]
r = cats[0]
assert r["recordedStatus"] == r["observedStatus"], r
assert r["bodyMatch"] == "fail", r
changed = [c for c in r["bodyChanges"]
           if c.get("kind") == "value_changed" and c.get("candidate") == "Datastore"]
assert changed, r["bodyChanges"]
# the fix signal survives alongside the body-only collateral
assert any((f["uri"] or "").startswith("/api/stats") for f in s["fixed"]), s["fixed"]
assert s["requestsFailed"] == 0, s["requestsFailed"]
print("PASS: body-only collateral caught with the status unchanged, fix still reported")
PY

echo "PASS: reproduce deterministic (0), fix confirmed (0), bug-still-present (2), status collateral (3), body-only collateral (3)"
