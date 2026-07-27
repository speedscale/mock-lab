#!/usr/bin/env bash
# Shared helpers for the skill scripts. Sourced, not executed:
#   source "$(dirname "$0")/../../lib/common.sh"
#
# Contract:
# - bash 3.2 compatible (macOS default), pure ASCII
# - functions only: no top-level side effects, no `set` option changes
# - every function is prefixed ql_ to avoid collisions with callers
# - callers keep their own `die`/`need_cmd` wrappers so each script's
#   documented exit-code contract is preserved (ql_die takes the code)
# - ql_prove_cleanup reads the caller globals `pids`, `ports`, and `tmp`
#   (documented contract for prove scripts; nothing else touches caller state)

ql_die() {
  # ql_die CODE MSG...: print "error: MSG" to stderr and exit CODE
  local code="$1"
  shift
  echo "error: $*" >&2
  exit "$code"
}

ql_fail() {
  # prove-script failure: print "FAIL: MSG" to stderr and exit 1
  echo "FAIL: $*" >&2
  exit 1
}

ql_need_cmd() {
  # ql_need_cmd CMD CODE: exit CODE unless CMD is on PATH
  command -v "$1" >/dev/null 2>&1 || ql_die "$2" "missing required command: $1"
}

ql_prove_need_cmd() {
  # prove-script variant of ql_need_cmd (FAIL prefix, exit 1)
  command -v "$1" >/dev/null 2>&1 || ql_fail "missing required command: $1"
}

ql_abs_path() {
  # print an absolute path for an existing dir, or dir-resolved path for a file
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

ql_check_proxymock_bin() {
  # ql_check_proxymock_bin BIN CODE: a BIN containing a slash must be an
  # executable file; a bare name must resolve on PATH
  if [[ "$1" == */* ]]; then
    [[ -x "$1" ]] || ql_die "$2" "proxymock is not executable: $1"
  else
    command -v "$1" >/dev/null 2>&1 || ql_die "$2" "proxymock not found on PATH"
  fi
}

ql_pick_port() {
  # print a free TCP port on 127.0.0.1
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

ql_wait_url() {
  # ql_wait_url URL: poll until an HTTP request to URL succeeds (60s budget)
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

# --- teardown -----------------------------------------------------------------
# `proxymock mock -- <app>` stops on SIGTERM and takes the wrapped app with it:
# measured on v2.5.812, the child dies first and both processes are gone in
# under 400ms, leaving the app and proxy-out ports free. Teardown is therefore
# SIGTERM, a short bounded wait, and a port check.
#
# The SIGKILL path below is a last-resort safety net, not the normal path. It
# was routine in v2.5.805, whose SIGTERM regression left the wrapper alive 30s+
# with its providers detached (the app kept LISTENING but answered wrong), and
# leaked the app binary on the port. Keep the net, because a stale listener
# silently poisons whatever runs next, but expect it never to fire; when it
# does, that is news.

ql_port_free() {
  # ql_port_free PORT: true when nothing holds the TCP port
  ! lsof -ti "tcp:${1}" >/dev/null 2>&1
}

ql_kill_pid() {
  # ql_kill_pid PID: SIGTERM, bounded wait (~2s), SIGKILL only if it survives
  local pid="$1" i
  kill "$pid" 2>/dev/null || true
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "WARNING: pid $pid outlived SIGTERM; escalating to SIGKILL" >&2
    kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
}

ql_sweep_port() {
  # ql_sweep_port PORT: verify the port is free after teardown and, only if it
  # is not, kill whatever still holds it. Returns 1 when it is still held.
  local port="$1" holders i
  ql_port_free "$port" && return 0
  holders="$(lsof -ti "tcp:${port}" 2>/dev/null || true)"
  [[ -n "$holders" ]] || return 0
  echo "WARNING: port $port still held after SIGTERM by pid(s): $holders" >&2
  kill $holders 2>/dev/null || true
  for i in 1 2 3 4; do
    ql_port_free "$port" && return 0
    sleep 0.25
  done
  holders="$(lsof -ti "tcp:${port}" 2>/dev/null || true)"
  [[ -n "$holders" ]] && kill -9 $holders 2>/dev/null
  for i in 1 2 3 4; do
    ql_port_free "$port" && return 0
    sleep 0.25
  done
  return 1
}

ql_stop_pid_and_port() {
  # ql_stop_pid_and_port PID PORT: stop the wrapper and verify the port is
  # free. Fails loudly (returns 1) when it is not: a surviving mock answers
  # requests with detached providers, so continuing would measure garbage.
  ql_kill_pid "$1"
  if ! ql_sweep_port "$2"; then
    echo "error: port $2 is STILL held after teardown by pid(s):" >&2
    lsof -ti "tcp:${2}" 2>/dev/null >&2 || true
    echo "error: a surviving 'proxymock mock' serves wrong answers with detached" >&2
    echo "error: providers; kill it before trusting any further measurement." >&2
    return 1
  fi
  return 0
}

ql_prove_cleanup() {
  # EXIT-trap handler for prove scripts. Reads the caller globals `pids`
  # (background pids started by the proof), `ports` (this proof's ports;
  # sweeping is scoped to these so other sessions on the host are untouched),
  # and `tmp` (the proof workspace, kept when KEEP_PROOF_TMP=1).
  local pid port
  for pid in "${pids[@]:-}"; do
    [[ -n "$pid" ]] || continue
    ql_kill_pid "$pid"
  done
  for port in "${ports[@]:-}"; do
    [[ -n "$port" ]] || continue
    ql_sweep_port "$port" || echo "WARNING: port $port still held after cleanup" >&2
  done
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}

ql_blueprint_dir() {
  # blueprints load ONLY from the recording's parent directory's blueprints/
  # subdir (the --in anchoring rule), never from cwd
  echo "$(dirname "$1")/blueprints"
}

ql_blueprint_count() {
  # count top-level *.json blueprints in a dir; 0 when the dir is absent
  local n=0
  if [[ -d "$1" ]]; then
    n="$(find "$1" -maxdepth 1 -name '*.json' -type f | wc -l | tr -d ' ')"
  fi
  echo "$n"
}

ql_smart_replace_file_count() {
  # count replay-output RRPair files carrying smart_replace events: direct
  # evidence that a blueprint's transform chains ran on THIS replay, which the
  # "Loaded blueprint ..." console lines do not tell you (they report loading,
  # not application).
  #
  # Do NOT reach for replay's --require-blueprint here: measured broken on
  # v2.5.812, where it exits 1 with "loaded but none of its transform chains
  # ran" against a blueprint that demonstrably ran. Revisit when that is fixed.
  (grep -ril 'smart_replace' "$1" 2>/dev/null || true) | wc -l | tr -d ' '
}

ql_has_outbound() {
  # true when the recording contains outbound (direction OUT) pairs
  grep -rl '"direction":"OUT"' "$1" >/dev/null 2>&1
}

ql_check_replay_out_empty() {
  # ql_check_replay_out_empty DIR CODE: refuse to replay into a dir that
  # already has content
  if [[ -d "$1" ]] && [[ -n "$(ls -A "$1" 2>/dev/null)" ]]; then
    ql_die "$2" "replay output dir already has content, pick a fresh --work-dir: $1"
  fi
}

ql_replay_rc=0

ql_run_replay() {
  # ql_run_replay BIN IN TARGET OUT RESULT_JSON LOG CODE [EXTRA_FLAG...]:
  # run proxymock replay with JSON metrics on stdout and extra flags appended
  # (--baseline / --fail-on-new-mismatch / --verify-fix / --expect).
  #
  # v2.5.812 scores response BODIES as well as status codes by default, so the
  # verdict carries bodyMatch / bodyChanges per pair and bodyMismatches in the
  # summary. Nothing here asks for that; pass --ignore-body-changes to replay
  # if you ever want the old status-only scoring back.
  #
  # Exit 2 (bug still reproduces) and 3 (new mismatch / collateral) are the
  # native verdict gate reporting a RESULT, not a failure: they are returned
  # in the global ql_replay_rc for the caller to map onto its own contract.
  # Anything else, or a missing metrics file / output dir / verdict file, is a
  # precondition failure and dies with CODE. Exit 1 covers the "nothing to
  # verify" cases (e.g. --expect matched no recorded-error pair), whose message
  # goes to STDOUT, so both streams are echoed on failure.
  local bin="$1" in="$2" target="$3" out="$4" result="$5" log="$6" code="$7"
  shift 7
  local rc=0
  "$bin" replay \
    --in "$in" \
    --test-against "$target" \
    --out "$out" \
    --output json "$@" >"$result" 2>"$log" || rc=$?
  ql_replay_rc="$rc"
  if [[ "$rc" -ne 0 && "$rc" -ne 2 && "$rc" -ne 3 ]] \
     || [[ ! -s "$result" || ! -d "$out" || ! -s "$out/replay-verdict.json" ]]; then
    cat "$result" >&2
    cat "$log" >&2
    ql_die "$code" "proxymock replay did not complete (exit $rc); see $log"
  fi
}

ql_echo_replay_verdict_lines() {
  # ql_echo_replay_verdict_lines LOG: surface proxymock's own verdict lines
  # from a captured replay log. The native wording is the contract; do not
  # reformat it.
  grep -E '^(NEW MISMATCH|FIX CONFIRMED|BUG REPRODUCED|COLLATERAL|Replay verdict):' "$1" || true
}

ql_advise_masked_different() {
  # ql_advise_masked_different VERDICT_JSON BASELINE_DIR: advisory only, never
  # a gate.
  #
  # Baseline masking is per-PAIR: known-mismatch means "this pair also failed in
  # the baseline", not "it fails the same way". v2.5.812 does catch the common
  # shape changes (401 -> 500 on an already-failing pair, or a body change at a
  # location the baseline did not fail at, both score newMismatch true), but a
  # delta the volatile heuristic owns is not counted, and that heuristic is not
  # stable: the same order_id value change was scored a value_changed regression
  # in one run and suppressed in another. So a real regression can hide behind a
  # known failure on the same pair.
  #
  # The two verdicts carry enough to spot it: compare this run's observedStatus
  # and bodyChanges against the baseline verdict's for the same refUuid, and
  # print the pairs where the failure is not the same failure.
  [[ -n "$2" && -s "$1" && -s "$2/replay-verdict.json" ]] || return 0
  python3 - "$1" "$2/replay-verdict.json" <<'PY'
import json, sys

def sig(p):
    changes = sorted((c.get("kind"), c.get("location"))
                     for c in (p.get("bodyChanges") or []))
    return (p.get("observedStatus"), tuple(changes))

def fmt(p):
    changes = sorted({c.get("kind") for c in (p.get("bodyChanges") or [])})
    return f"status {p.get('observedStatus')}" + (
        " body " + ",".join(c for c in changes if c) if changes else "")

cur, base = (json.load(open(a)) for a in sys.argv[1:3])
base_pairs = {p.get("refUuid"): p for p in (base.get("pairs") or [])}
advisories = []
for p in cur.get("pairs") or []:
    if p.get("newMismatch") is not False:
        continue
    if p.get("match") == "pass" and p.get("bodyMatch", "pass") == "pass":
        continue
    b = base_pairs.get(p.get("refUuid"))
    if b is None or sig(b) == sig(p):
        continue
    advisories.append((p, b))

for p, b in advisories:
    print(f"ADVISORY: masked but different: {p.get('method')} {p.get('endpoint')}"
          " is known-mismatch, yet")
    print(f"ADVISORY:   baseline failed as {fmt(b)}; now fails as {fmt(p)}")
if advisories:
    print("ADVISORY: known-mismatch means the pair also failed in the baseline,"
          " not that it")
    print("ADVISORY: failed the same way. Inspect the pairs above by hand; the"
          " gate will not.")
PY
}

ql_write_recording_stub() {
  # ql_write_recording_stub FILE: write a python3 stub server that answers with
  # the RECORDED status and body for each (method, path) in a recording dir, so
  # a proof exercises real body scoring instead of drowning every pair in
  # body mismatches. Usage:
  #   python3 FILE PORT RECORDING_DIR ['{"/api/stats":{"status":404}}']
  # Override keys are matched as path prefixes; each may set "status" and/or
  # "replace": [from, to] to seed a body-only change.
  cat >"$1" <<'PYEOF'
import json, os, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, recording = int(sys.argv[1]), sys.argv[2]
overrides = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}

def blocks(section):
    return re.findall(r"```\n(.*?)```", section, re.S)

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
        rb, sb = blocks(req), blocks(res)
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

class Handler(BaseHTTPRequestHandler):
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

    do_GET = respond
    do_POST = respond
    do_PUT = respond
    do_DELETE = respond

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PYEOF
}
