#!/usr/bin/env bash
# Proves: a baseline replay of the committed recording passes clean, a second
# gated run against the same target reports no regression (the known moving-ID
# noise floor does not false-positive), and a target that changes one
# endpoint's status code trips the match-tag gate (exit 3) while
# requests.failed stays 0.
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
stub_port="$(ql_pick_port)"
ports=("$app_port" "$out_port" "$health_port" "$stub_port")

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

echo "step 3: regressed target (GET /api/stats now 404; expect exit 3)"
# Stub returns the recorded status for every endpoint except /api/stats, so
# every HTTP exchange completes: the regression is invisible to
# requests.failed and only the match tag can catch it.
cat >"$tmp/stub.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def respond(self):
        status = 200
        if self.path.startswith("/api/stats"):
            status = 404  # the seeded regression
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

HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PYEOF
python3 "$tmp/stub.py" "$stub_port" &
pids+=("$!")
ql_wait_url "http://127.0.0.1:${stub_port}/" || die "regression stub did not start"

regress_rc=0
"$regress_script" \
  --in "$recording" \
  --test-against "http://127.0.0.1:${stub_port}" \
  --baseline "$tmp/base/replayed" \
  --fail-on-regression \
  --work-dir "$tmp/regressed" >"$tmp/regressed.out" 2>&1 || regress_rc=$?
cat "$tmp/regressed.out"
[[ "$regress_rc" -eq 3 ]] || die "expected exit 3 (match-tag regression), got $regress_rc"

python3 - "$tmp/regressed/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
new = s["match"]["newFailures"]
if not new:
    raise SystemExit("no new match failures recorded in summary.json")
if not any((p.get("uri") or "").startswith("/api/stats") for p in new):
    raise SystemExit(f"/api/stats not among new failures: {new}")
if s.get("requestsFailed") != 0:
    raise SystemExit(f"expected requests.failed == 0, got {s.get('requestsFailed')}")
print(f"PASS: {len(new)} new match failure(s), requests.failed=0, exit gate fired")
PY

echo "PASS: baseline clean, noise floor stable, seeded status regression caught (exit 3)"
