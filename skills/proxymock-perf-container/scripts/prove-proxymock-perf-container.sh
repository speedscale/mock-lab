#!/usr/bin/env bash
# Proves the perf-container contract hermetically (no cloud, no live
# downstream, no app build) against a local stub target:
#   a) ladder "1,2", no assertions            -> exit 0, summary.json carries
#      the ladder with per-level cpu attribution and a knee
#   b) absurd --assert-rps 10000000           -> exit 2 (assertion failed)
#   c) missing --in                           -> exit 4 (precondition)
#   d) PERF_FORCE_HARNESS_BOUND=1 + assertion -> exit 3 (harness-bound). The
#      real gate needs a saturated host, which a hermetic proof cannot force,
#      so the documented test hook stands in for it.
# Cases a and b run with PERF_FORCE_HARNESS_CLEAN=1 for the mirror-image
# reason: the real gate reads actual host state, so on a host that is busy
# with unrelated work it would (correctly) refuse and flip a/b to exit 3.
# The gate's own verdict path is what case d covers.
set -euo pipefail

die() {
  echo "FAIL: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_url() {
  local url="$1"
  local deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$skill_dir/../.." && pwd)"
perf_script="$script_dir/proxymock-perf-container.sh"

need_cmd curl
need_cmd proxymock
need_cmd python3
need_cmd lsof
need_cmd pgrep
[[ -x "$perf_script" ]] || die "perf script is not executable: $perf_script"

recording="$repo_root/lab/proxymock/recording/localhost"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-perf-container-proof.$$"
pids=()
ports=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # sweep any survivor still bound to a proof port
  for port in "${ports[@]:-}"; do
    [[ -n "$port" ]] || continue
    lsof -ti "tcp:${port}" 2>/dev/null | xargs kill 2>/dev/null || true
  done
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp"

# --- stub target -------------------------------------------------------------
# Returns the recorded status for every endpoint in the committed recording so
# all HTTP exchanges complete. Threaded, keep-alive HTTP/1.1 so it survives
# multi-VU load.
cat >"$tmp/stub.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def respond(self):
        status = 201 if (self.command == "POST" and self.path == "/api/orders") else 200
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

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF

stub_port="$(pick_port)"
ports=("$stub_port")
python3 "$tmp/stub.py" "$stub_port" &
pids+=("$!")
wait_url "http://127.0.0.1:${stub_port}/" || die "stub did not start"
target="http://127.0.0.1:${stub_port}"

# --- case a: ladder run, report-only (expect exit 0) -------------------------
echo "case a: ladder 1,2 with no assertions (report-only)"
PERF_FORCE_HARNESS_CLEAN=1 "$perf_script" \
  --in "$recording" \
  --test-against "$target" \
  --vus-ladder "1,2" --for 3s \
  --work-dir "$tmp/ladder" >"$tmp/ladder.out" 2>&1 || {
    cat "$tmp/ladder.out" >&2
    die "case a: report-only ladder run should exit 0"
  }
cat "$tmp/ladder.out"
python3 - "$tmp/ladder/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
ladder = s["ladder"]
assert [r["vus"] for r in ladder] == [1, 2], ladder
for r in ladder:
    assert isinstance(r["rps"], (int, float)) and r["rps"] > 0, r
    cpu = r["cpu"]
    for k in ("generatorMaxPct", "appMaxPct", "hostIdleMinPct", "samples"):
        assert k in cpu, (r["vus"], cpu)
    assert cpu["samples"] >= 1, (r["vus"], cpu)
    assert "matchPct" in r and "latencyMs" in r, r
# attribution actually measured something, not just carried empty fields
assert any(r["cpu"]["generatorMaxPct"] is not None for r in ladder), ladder
assert any(r["cpu"]["hostIdleMinPct"] is not None for r in ladder), ladder
assert s["knee"] is not None and s["knee"]["vus"] in (1, 2), s["knee"]
assert s["assertLevel"] is not None and len(s["assertLevel"]["samples"]) >= 1
assert s["exitCode"] == 0, s["exitCode"]
print("PASS: ladder + per-level cpu attribution + knee in summary.json")
PY

# --- case b: absurd rps assertion (expect exit 2) ----------------------------
echo "case b: --assert-rps 10000000 fails at the knee"
rc=0
PERF_FORCE_HARNESS_CLEAN=1 "$perf_script" \
  --in "$recording" \
  --test-against "$target" \
  --vus-ladder "1" --for 3s --repeats 1 \
  --assert-rps 10000000 \
  --work-dir "$tmp/assert-fail" >"$tmp/assert-fail.out" 2>&1 || rc=$?
cat "$tmp/assert-fail.out"
[[ "$rc" -eq 2 ]] || die "case b: expected exit 2 (assertion failed), got $rc"
python3 - "$tmp/assert-fail/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["assertions"]["rps"]["verdict"] == "fail", s["assertions"]
assert s["exitCode"] == 2, s["exitCode"]
print("PASS: failed rps assertion reported and exit 2")
PY

# --- case c: missing --in (expect exit 4) ------------------------------------
echo "case c: missing --in is a precondition failure"
rc=0
"$perf_script" --test-against "$target" >"$tmp/precondition.out" 2>&1 || rc=$?
cat "$tmp/precondition.out"
[[ "$rc" -eq 4 ]] || die "case c: expected exit 4 (precondition), got $rc"

# --- case d: harness-bound via the documented test hook (expect exit 3) ------
# The real gate fires on host saturation, which this proof cannot force
# without wrecking hermeticity; PERF_FORCE_HARNESS_BOUND=1 exists for exactly
# this check. The assertion (>= 1 rps) would trivially pass, proving exit 3
# comes from the harness-bound refusal, not from the assertion.
echo "case d: harness-bound refusal beats a passing assertion"
rc=0
PERF_FORCE_HARNESS_BOUND=1 "$perf_script" \
  --in "$recording" \
  --test-against "$target" \
  --vus-ladder "1" --for 3s --repeats 1 \
  --assert-rps 1 \
  --work-dir "$tmp/harness-bound" >"$tmp/harness-bound.out" 2>&1 || rc=$?
cat "$tmp/harness-bound.out"
[[ "$rc" -eq 3 ]] || die "case d: expected exit 3 (harness-bound), got $rc"
python3 - "$tmp/harness-bound/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["knee"] is None, s["knee"]
assert s["harnessNote"] is not None, s
assert s["exitCode"] == 3, s["exitCode"]
print("PASS: no app ceiling printed, harness-bound refusal exits 3")
PY

echo "PASS: report-only (0), assertion failure (2), precondition (4), harness-bound (3)"
