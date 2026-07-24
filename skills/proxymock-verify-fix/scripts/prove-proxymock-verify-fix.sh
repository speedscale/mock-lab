#!/usr/bin/env bash
# Proves the semantic inversion end to end, hermetically (no cloud, no live
# downstream, no app build). It fabricates an incident recording by flipping
# one GET pair's recorded status to 500 in a copy of the committed recording,
# then drives the verify script through four sub-cases against stub targets:
#   a) --reproduce vs a buggy stub (500 on the incident path)  -> exit 0
#   b) verify vs a fixed stub (recorded statuses everywhere)   -> exit 0
#   c) verify vs the buggy stub (all pairs match)              -> exit 2
#   d) verify vs a stub with a second, unrelated discrepancy   -> exit 3
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
# Copy the committed recording into its own proxymock workspace (so blueprint
# anchoring resolves) and flip GET /api/stats from 200 to 500: the incident
# capture stores the FAILING response as recorded truth.
echo "fabricating incident recording (GET /api/stats recorded 500)"
mkdir -p "$tmp/incident"
cp -R "$recording" "$tmp/incident/recording"
[[ -d "$blueprints" ]] && cp -R "$blueprints" "$tmp/incident/blueprints"

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
# Each stub returns the recorded status for every endpoint so all HTTP
# exchanges complete (requests.failed stays 0) and only the match tags carry
# the signal. STATS_STATUS and CATEGORIES_STATUS parameterize the scenario.
cat >"$tmp/stub.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, stats_status, categories_status = (int(a) for a in sys.argv[1:4])

class Handler(BaseHTTPRequestHandler):
    def respond(self):
        status = 200
        if self.path.startswith("/api/stats"):
            status = stats_status
        elif self.path.startswith("/api/categories"):
            status = categories_status
        elif self.command == "POST" and self.path == "/api/orders":
            status = 201  # recorded status
        body = b"{}"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = respond
    do_POST = respond

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

buggy_port="$(ql_pick_port)"       # stats 500: the bug, matching the incident recording
fixed_port="$(ql_pick_port)"       # stats 200: the fix
collateral_port="$(ql_pick_port)"  # stats 200 but categories 404: fix plus collateral
ports=("$buggy_port" "$fixed_port" "$collateral_port")

python3 "$tmp/stub.py" "$buggy_port" 500 200 &
pids+=("$!")
python3 "$tmp/stub.py" "$fixed_port" 200 200 &
pids+=("$!")
python3 "$tmp/stub.py" "$collateral_port" 200 404 &
pids+=("$!")
ql_wait_url "http://127.0.0.1:${buggy_port}/" || die "buggy stub did not start"
ql_wait_url "http://127.0.0.1:${fixed_port}/" || die "fixed stub did not start"
ql_wait_url "http://127.0.0.1:${collateral_port}/" || die "collateral stub did not start"

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

echo "PASS: reproduce deterministic (0), fix confirmed (0), bug-still-present (2), collateral (3)"
