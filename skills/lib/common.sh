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

ql_sweep_port() {
  # kill anything still bound to the TCP port. Needed because SIGTERM to a
  # wrapper (proxymock mock) can strand its child app on the port.
  lsof -ti "tcp:${1}" 2>/dev/null | xargs kill 2>/dev/null || true
}

ql_stop_pid_and_port() {
  # ql_stop_pid_and_port PID PORT: SIGTERM the pid, reap it, then sweep any
  # survivor still bound to the port
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
  ql_sweep_port "$2"
}

ql_prove_cleanup() {
  # EXIT-trap handler for prove scripts. Reads the caller globals `pids`
  # (background pids started by the proof), `ports` (this proof's ports;
  # sweeping is scoped to these so other sessions on the host are untouched),
  # and `tmp` (the proof workspace, kept when KEEP_PROOF_TMP=1).
  local pid port
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for port in "${ports[@]:-}"; do
    [[ -n "$port" ]] || continue
    ql_sweep_port "$port"
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
  # count replay-output RRPair files carrying smart_replace events: the only
  # trustworthy signal that a blueprint applied. The console line "Applied N
  # active blueprint(s)" reflects snapshot-scoped state, not the workspace,
  # so it can report blueprints that never touched the replay.
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

ql_run_replay() {
  # ql_run_replay BIN IN TARGET OUT RESULT_JSON LOG CODE: run proxymock
  # replay with JSON metrics on stdout; die CODE unless it completed and
  # produced both the metrics file and the replay output dir
  local bin="$1" in="$2" target="$3" out="$4" result="$5" log="$6" code="$7"
  local rc=0
  "$bin" replay \
    --in "$in" \
    --test-against "$target" \
    --out "$out" \
    --output json >"$result" 2>"$log" || rc=$?
  if [[ "$rc" -ne 0 || ! -s "$result" || ! -d "$out" ]]; then
    cat "$log" >&2
    ql_die "$code" "proxymock replay did not complete (exit $rc); see $log"
  fi
}
