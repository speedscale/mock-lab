#!/usr/bin/env bash
# Proves the exit-code contract of every documented native command in this pack,
# against the committed lab recording. Hermetic: no cloud, no live downstream,
# no app build. One proof for the whole pack -- a documented deviation from the
# repo's one-prove-per-skill convention, since all five loop skills now run the
# same binary and per-skill proofs would be five copies of these assertions.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
ql="$script_dir/quality-loop.sh"
recording="$repo_root/lab/proxymock/recording"
spec="$repo_root/lab/openapi.yaml"

need proxymock; need python3; need curl; need lsof
[[ -x "$ql" ]] || fail "dispatcher is not executable: $ql"
[[ -d "$recording" ]] || fail "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/quality-loop-proof.$$"
mkdir -p "$tmp"
pids=()
cleanup() {
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
  [[ "${KEEP_PROOF_TMP:-0}" == "1" ]] && { echo "kept: $tmp"; return; }
  rm -rf "$tmp"
}
trap cleanup EXIT

# Give this run its own speedscale home. Every proxymock command INGESTS its
# --in into <speedscale-home>/data/snapshots/ under one fixed local snapshot id,
# so two concurrent proxymock processes with different --in clobber each other's
# raw.jsonl and the loser replays the WINNER's recording -- surfacing as
# "references refUuid <uuid> not found in --in" with no verdict written, or
# silently as a verdict scored against the wrong recording. The certs/ copy
# matters too: a fresh home mints a CA nothing in the environment trusts.
pm=(proxymock)
if [[ -r "$HOME/.speedscale/config.yaml" ]]; then
  mkdir -p "$tmp/home"
  cp "$HOME/.speedscale/config.yaml" "$tmp/home/config.yaml"
  chmod 600 "$tmp/home/config.yaml" 2>/dev/null || true
  [[ -d "$HOME/.speedscale/certs" ]] && cp -R "$HOME/.speedscale/certs" "$tmp/home/certs" 2>/dev/null
  pm=(proxymock --config "$tmp/home/config.yaml")
else
  echo "WARNING: no ~/.speedscale/config.yaml to copy; sharing the global snapshot dir" >&2
fi

# expect_rc WANT NAME CMD...: run CMD, capture output to $tmp/NAME.out, assert rc
expect_rc() {
  local want="$1" name="$2" rc=0
  shift 2
  "$@" >"$tmp/$name.out" 2>&1 || rc=$?
  [[ "$rc" -eq "$want" ]] || { cat "$tmp/$name.out" >&2; fail "$name exited $rc, want $want"; }
}
saw() { grep -q "$2" "$tmp/$1.out" || { cat "$tmp/$1.out" >&2; fail "$1: missing '$2'"; }; }

# A stub that answers with the RECORDED status and body for each (method, path),
# so a replay exercises real body scoring instead of drowning in body
# mismatches. argv: PORT RECORDING ['{"/path":{"status":404,"replace":[a,b]}}']
cat >"$tmp/stub.py" <<'PY'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, recording = int(sys.argv[1]), sys.argv[2]
overrides = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
recorded = {}
for root, _, files in os.walk(recording):
    for name in files:
        if not name.endswith(".md"):
            continue
        text = open(os.path.join(root, name)).read()
        if "### REQUEST ###" not in text or "### RESPONSE ###" not in text:
            continue
        req = text.split("### REQUEST ###")[1].split("### RESPONSE ###")[0]
        res = text.split("### RESPONSE ###")[1].split("### SIGNATURE ###")[0]
        rb, sb = re.findall(r"```\n(.*?)```", req, re.S), re.findall(r"```\n(.*?)```", res, re.S)
        if not rb or not sb:
            continue
        method, url = rb[0].split("\n")[0].split()[:2]
        path = re.sub(r"^https?://[^/]+", "", url) or "/"
        status = int(sb[0].split("\n")[0].split()[1])
        ctype = "application/json"
        for line in sb[0].split("\n")[1:]:
            if line.lower().startswith("content-type:"):
                ctype = line.split(":", 1)[1].strip()
        recorded[(method, path)] = (status, sb[1] if len(sb) > 1 else "", ctype)

class H(BaseHTTPRequestHandler):
    def respond(self):
        status, body, ctype = recorded.get(
            (self.command, self.path), (404, "", "application/json"))
        for prefix, over in overrides.items():
            if self.path.startswith(prefix):
                status = over.get("status", status)
                if "replace" in over:
                    body = body.replace(over["replace"][0], over["replace"][1])
        raw = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    do_GET = do_POST = do_PUT = do_DELETE = respond
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY

stub() {
  # stub NAME RECORDING [OVERRIDES_JSON] -> sets $target to its base URL.
  # localhost, not 127.0.0.1: the address spelling is what a network_address
  # blueprint filter would bind to, so keep the documented one.
  local p; p="$(port)"
  python3 "$tmp/stub.py" "$p" "$2" ${3+"$3"} &
  pids+=($!)
  local i
  for i in $(seq 1 40); do
    curl -fsS -o /dev/null "http://127.0.0.1:$p/api/projects" 2>/dev/null && break
    sleep 0.25
  done
  curl -fsS -o /dev/null "http://127.0.0.1:$p/api/projects" || fail "$1: stub never came up"
  target="http://localhost:$p"
}

echo "== 1. doctor: 0 healthy against this repo, 1 against an empty root, 2 on usage"
expect_rc 0 doctor-repo bash "$ql" doctor --root "$repo_root"
saw doctor-repo "lab/proxymock/recording"
saw doctor-repo "mocklab-smart-replace.json"
saw doctor-repo "^healthy:"
mkdir -p "$tmp/empty"
expect_rc 1 doctor-empty bash "$ql" doctor --root "$tmp/empty"
saw doctor-empty "^MISSING:"
saw doctor-empty "no RRPair recording dirs"
expect_rc 2 bogus bash "$ql" not-a-mode
saw bogus "unknown mode: not-a-mode"
expect_rc 2 bare bash "$ql"
expect_rc 2 noargs bash "$ql" regression --in "$recording"
echo "ok: doctor and usage contract"

echo "== 2. regression: 0 on a faithful target, 3 on a status regression, 3 on a body-only one"
stub faithful "$recording"
expect_rc 0 reg-base "${pm[@]}" replay --in "$recording" --test-against "$target" \
  --out "$tmp/baseline"
saw reg-base "Loaded blueprint"
grep -q '"verdict": *"pass"' "$tmp/baseline/replay-verdict.json" \
  || fail "baseline verdict is not pass"

stub status404 "$recording" '{"/api/stats":{"status":404}}'
expect_rc 3 reg-status "${pm[@]}" replay --in "$recording" --test-against "$target" \
  --out "$tmp/reg-status" --baseline "$tmp/baseline" --fail-on-new-mismatch
saw reg-status "NEW MISMATCH: GET /api/stats recorded 200 -> observed 404"
# the point of the whole gate: transport metrics stay clean through a status regression
grep -qE '"failed": *0|FAILED .*0%|│ *0% │' "$tmp/reg-status.out" \
  || fail "expected requests.failed to stay 0 across a status regression"

stub bodyonly "$recording" '{"/api/stats":{"replace":["24","25"]}}'
expect_rc 3 reg-body "${pm[@]}" replay --in "$recording" --test-against "$target" \
  --out "$tmp/reg-body" --baseline "$tmp/baseline" --fail-on-new-mismatch
saw reg-body "/api/stats"
echo "ok: regression exits 0 / 3 / 3"

echo "== 3. verify-fix: the inversion, both directions"
cp -R "$recording" "$tmp/incident"
rm -rf "$tmp/incident/.replay"
python3 - "$(grep -rln 'api/stats' "$tmp/incident/localhost" | head -1)" <<'PY'
import sys
p = sys.argv[1]
req, res = open(p).read().split("### RESPONSE ###", 1)
open(p, "w").write(req + "### RESPONSE ###" +
                   res.replace("HTTP/1.1 200 OK", "HTTP/1.1 500 Internal Server Error", 1))
PY
stub fixed "$recording"
expect_rc 0 vf-fixed "${pm[@]}" replay --in "$tmp/incident" --test-against "$target" \
  --out "$tmp/vf-fixed" --verify-fix --expect '/api/stats'
saw vf-fixed "FIX CONFIRMED: GET /api/stats recorded 500 -> observed 200"

stub buggy "$tmp/incident"
expect_rc 2 vf-buggy "${pm[@]}" replay --in "$tmp/incident" --test-against "$target" \
  --out "$tmp/vf-buggy" --verify-fix --expect '/api/stats'
saw vf-buggy "BUG REPRODUCED"
echo "ok: an all-match run is exit 2 (bug still reproduces), the fix is exit 0"

echo "== 4. contract: 0 conformant, 2 violating, 3 without a spec route"
expect_rc 0 val-ok "${pm[@]}" validate --spec "$spec" \
  --in "$recording/demo-api.trafficreplay.com"
saw val-ok "5 conformant, 0 violating"
cp -R "$recording/demo-api.trafficreplay.com" "$tmp/badpairs"
python3 - "$(grep -rln '"stars"' "$tmp/badpairs" | head -1)" <<'PY'
import re, sys
p = sys.argv[1]
text = open(p).read()
open(p, "w").write(re.sub(r'"stars":\s*\d+', '"stars": "many"', text, count=1))
PY
expect_rc 2 val-bad "${pm[@]}" validate --spec "$spec" --in "$tmp/badpairs"
saw val-bad 'stars: type mismatch, expected integer, got string'
# the asymmetry: the app's own inbound API has no spec, so its routes are absent
expect_rc 3 val-noroute "${pm[@]}" validate --spec "$spec" --in "$recording/localhost"
saw val-noroute "NO_ROUTE"
echo "ok: validate exits 0 / 2 / 3"

echo "== 5. chaos: faults fire on the unmodified recording, and a no-match pattern warns"
mport="$(port)"; hport="$(port)"
"${pm[@]}" mock --in "$recording" --proxy-out-port "$mport" --health-port "$hport" \
  --no-out --fault '/v1/projects:status=503' --fault '/v1/categories:status=503,rate=1/3' \
  >"$tmp/mock.out" 2>&1 &
mock_pid=$!
pids+=("$mock_pid")
for i in $(seq 1 60); do curl -fsS -o /dev/null "http://127.0.0.1:$hport" 2>/dev/null && break; sleep 0.25; done
curl -fsS -o /dev/null "http://127.0.0.1:$hport" || { cat "$tmp/mock.out" >&2; fail "mock never came up"; }
probe() { curl -s -o /dev/null -m 10 -w '%{http_code}' \
  -x "http://127.0.0.1:$mport" "http://demo-api.trafficreplay.com$1"; }
[[ "$(probe /v1/projects)" == "503" ]] || fail "status fault did not fire on the target"
curl -s -D- -o /dev/null -m 10 -x "http://127.0.0.1:$mport" \
  "http://demo-api.trafficreplay.com/v1/projects" \
  | grep -qi '^x-speedscale-chaos: proxymock fault' || fail "chaos header missing"
got=""
for i in 1 2 3 4 5 6; do got+="$(probe /v1/categories) "; done
[[ "$got" == "503 200 200 503 200 200 " ]] || fail "rate=1/3 is not exact and periodic: '$got'"
kill "$mock_pid" 2>/dev/null || true
sleep 0.5

# scheme+port is not in the candidate string, so this plausible pattern matches
# nothing; proxymock says so rather than serving a silent no-op
mport2="$(port)"; hport2="$(port)"
"${pm[@]}" mock --in "$recording" --proxy-out-port "$mport2" --health-port "$hport2" \
  --no-out --fault 'https://demo-api.trafficreplay.com:443/v1/projects:status=503' \
  >"$tmp/mock-nomatch.out" 2>&1 &
mock_pid=$!
pids+=("$mock_pid")
for i in $(seq 1 60); do curl -fsS -o /dev/null "http://127.0.0.1:$hport2" 2>/dev/null && break; sleep 0.25; done
grep -qi "matches no mock data" "$tmp/mock-nomatch.out" \
  || { cat "$tmp/mock-nomatch.out" >&2; fail "a fault pattern matching nothing did not warn"; }
kill "$mock_pid" 2>/dev/null || true
echo "ok: 503 on the target, exact 1/3 periodicity, chaos header, no-match warning"

echo "== 6. load: 0 on a completed run, 1 when a --fail-if threshold trips"
stub load "$recording"
expect_rc 0 load-ok "${pm[@]}" replay --in "$recording/localhost" --test-against "$target" \
  --out "$tmp/load-ok" --vus 2 --for 3s --load-test
expect_rc 1 load-gate "${pm[@]}" replay --in "$recording/localhost" --test-against "$target" \
  --out "$tmp/load-gate" --vus 2 --for 3s --load-test --fail-if "requests.per-second>0.001"
saw load-gate "requests.per-second"
echo "ok: load exits 0, and 1 on a tripped --fail-if"

echo
echo "PASS: every documented native command holds its exit-code contract"
