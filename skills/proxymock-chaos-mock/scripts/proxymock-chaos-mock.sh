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
  proxymock-chaos-mock.sh --in DIR --scenario NAME --target PATTERN [options]
  proxymock-chaos-mock.sh --flip-body FILE --target PATTERN --work-dir DIR
  proxymock-chaos-mock.sh --restore --work-dir DIR

Make a mocked downstream lie to your service using proxymock's native
`mock --fault` injection. The recording is served AS IS: no copy, no edits,
no variant to validate. Faults are flags on the mock process.

Scenarios (--scenario) and the fault they build:
  down       status=503
  ratelimit  status=429,header=Retry-After:<n>
  garbage    body=corrupt (or --body-fault truncate[:BYTES])
  slow       latency=<duration>, or the GLOBAL --mock-timing multiplier when
             --latency is 'Nx' (every endpoint, --target advisory only)
  connection connection=refuse|reset|stall|drop (--connection, default reset).
             Fires on HTTP/1.1 and HTTP/2 recordings alike. refuse and reset
             are indistinguishable to most clients; stall needs a client
             timeout; drop returns a 200 with a truncated body.
  flaky      status=503,rate=F/N

--ratio F/N composes with ANY scenario, so `--scenario ratelimit --ratio 1/3`
is a 429 on the first request of every 3. rate=F/N is deterministic and
periodic, not probabilistic.

--target is the fault regexp (RE2). It is UNANCHORED and matched against the
bare path AND host+path; scheme, port, and METHOD are NOT in the candidate
string, so 'https://api.example.com:443/v1/projects' parses, starts, and
matches nothing. Use a plain path substring like '/v1/projects'.

Required (fault mode): --in DIR, --scenario NAME, --target PATTERN

Options:
  --latency VALUE       slow only: Go duration with a UNIT ('2500ms', '1.5s'),
                        or 'Nx' for the global multiplier. Required for slow.
  --ratio F/N           rate=F/N composed with the scenario's actions
                        (flaky defaults to 1/2; other scenarios default off)
  --retry-after N       ratelimit only: Retry-After seconds (default 30)
  --body-fault SPEC     garbage only: corrupt | truncate | truncate:BYTES
  --connection ACTION   connection only: refuse|reset|stall|drop (default reset)
  --custom-body FILE    Serve FILE as the matched pairs' response body. Needs
                        an RRPair edit (body= only does corrupt/truncate), so
                        this and only this makes a writable copy of the
                        recording in <work-dir>/recording.
  --work-dir DIR        Where serve state and any copy land (default: a
                        timestamped dir)
  --serve               Start the faulted mock in the background, un-wrapped
  --proxy-out-port N    Mock proxy port for --serve (default 4140)
  --health-port N       Mock health port for --serve (default: a free port)
  --reload-interval DUR --mock-reload-interval for --serve (default 1s). Mock
                        DATA hot-reloads at this interval; --fault does NOT.
  --flip-body FILE      Mid-session flip: rewrite the matched pairs' response
                        body in the running mock's copy (--work-dir) and let
                        hot reload pick it up (~1s). Requires a work dir
                        created with --custom-body.
  --restore             Stop the faulted mock recorded in --work-dir and
                        restart it on the same ports with no faults and the
                        pristine recording
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

Exit codes:
  0  fault command ready (and serving, if --serve); flip or restore done
  2  --target matched no loaded outbound pair (a fault that matches nothing
     is a SILENT no-op, so this is a correctness gate, not a nicety)
  3  the mock did not come up
  4  precondition or usage failure

Output files (in --work-dir, only with --serve):
  serve.json   pid, ports, and the exact fault specs in use
  mock.log     the running mock's log
  recording/   writable copy, ONLY when --custom-body is used

Examples:
  # downstream 503s on one endpoint; serve the lying mock
  proxymock-chaos-mock.sh --in ./proxymock/recording \
    --scenario down --target '/v1/projects' --serve

  # exact 1-in-3 deterministic 429s with a Retry-After hint
  proxymock-chaos-mock.sh --in ./proxymock/recording \
    --scenario ratelimit --target '/v1/projects' --ratio 1/3 --serve

  # put the healthy downstream back
  proxymock-chaos-mock.sh --restore --work-dir ./chaos-work
USAGE
}

# precondition failures use exit 4 per the output contract
die() { ql_die 4 "$@"; }
need_cmd() { ql_need_cmd "$1" 4; }

in_dir=""
scenario=""
target=""
latency=""
ratio=""
retry_after="30"
body_fault="corrupt"
connection="reset"
custom_body=""
flip_body=""
work_dir=""
serve="0"
restore="0"
proxy_out_port="4140"
health_port=""
reload_interval="1s"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --scenario) [[ $# -ge 2 ]] || die "--scenario requires a value"; scenario="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || die "--target requires a value"; target="$2"; shift 2 ;;
    --latency) [[ $# -ge 2 ]] || die "--latency requires a value"; latency="$2"; shift 2 ;;
    --ratio) [[ $# -ge 2 ]] || die "--ratio requires a value"; ratio="$2"; shift 2 ;;
    --retry-after) [[ $# -ge 2 ]] || die "--retry-after requires a value"; retry_after="$2"; shift 2 ;;
    --body-fault) [[ $# -ge 2 ]] || die "--body-fault requires a value"; body_fault="$2"; shift 2 ;;
    --connection) [[ $# -ge 2 ]] || die "--connection requires a value"; connection="$2"; shift 2 ;;
    --custom-body) [[ $# -ge 2 ]] || die "--custom-body requires a value"; custom_body="$2"; shift 2 ;;
    --flip-body) [[ $# -ge 2 ]] || die "--flip-body requires a value"; flip_body="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --serve) serve="1"; shift ;;
    --restore) restore="1"; shift ;;
    --proxy-out-port) [[ $# -ge 2 ]] || die "--proxy-out-port requires a value"; proxy_out_port="$2"; shift 2 ;;
    --health-port) [[ $# -ge 2 ]] || die "--health-port requires a value"; health_port="$2"; shift 2 ;;
    --reload-interval) [[ $# -ge 2 ]] || die "--reload-interval requires a value"; reload_interval="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_cmd python3
need_cmd curl
need_cmd lsof
ql_check_proxymock_bin "$proxymock_bin" 4

wait_health() {
  # wait_health PID HEALTH_PORT -> 0 ready, 1 died or never became ready
  local pid="$1" port="$2"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    kill -0 "$pid" 2>/dev/null || return 1
    curl -fsS -m 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

wait_port_listening() {
  # the health endpoint can report 200 before the outbound proxy port accepts
  # connections (observed while a restarted mock rebinds), so wait explicitly
  local port="$1"
  local deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    if python3 - "$port" <<'PY'
import socket, sys
s = socket.socket()
s.settimeout(1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
    then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# rewrite the response body of every pair matching a fault pattern. Native
# body= only does corrupt/truncate, so scenario-accurate payloads (rate-limit
# envelopes, schema drift) still need an RRPair edit.
edit_bodies() {
  # edit_bodies RECORDING TARGET BODY_FILE
  python3 - "$1" "$2" "$3" <<'PY'
import json, pathlib, re, sys

rec, target, body_file = sys.argv[1:4]
body = pathlib.Path(body_file).read_text()
pat = re.compile(target)
edited = 0
for path in sorted(pathlib.Path(rec).rglob("*.md")):
    text = path.read_text(errors="ignore")
    m = re.search(r"json:\s*(\{.*\})", text, re.S)
    if not m:
        continue
    try:
        rr = json.loads(m.group(1))
    except Exception:
        continue
    if rr.get("direction") != "OUT":
        continue
    req = rr.get("http", {}).get("req", {})
    uri = req.get("uri") or ""
    host = (req.get("host") or "").split(":")[0]
    if not any(pat.search(c) for c in (uri, host + uri)):
        continue
    resp = text.index("### RESPONSE ###")
    end = text.index("### SIGNATURE ###")
    fences = list(re.finditer(r"(?ms)^```\n(.*?)^```", text[resp:end]))
    if len(fences) != 2:
        print(f"error: no response body block in {path}", file=sys.stderr)
        sys.exit(4)
    f = fences[1]
    start, stop = resp + f.start(1), resp + f.end(1)
    # Content-Length is recomputed and sanitized by the responder, so the
    # body block is the only thing that needs to change
    path.write_text(text[:start] + body.rstrip("\n") + "\n" + text[stop:])
    edited += 1
print(f"rewrote {edited} response body/bodies")
PY
}

read_serve_field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"
}

# --- flip mode ----------------------------------------------------------------
if [[ -n "$flip_body" ]]; then
  [[ -n "$work_dir" ]] || die "--flip-body requires --work-dir"
  [[ -n "$target" ]] || die "--flip-body requires --target"
  [[ -r "$flip_body" ]] || die "--flip-body file is not readable: $flip_body"
  work_dir="$(ql_abs_path "$work_dir")"
  serve_json="$work_dir/serve.json"
  [[ -s "$serve_json" ]] || die "no serve.json in $work_dir; nothing is serving"
  served="$(read_serve_field "$serve_json" servedRecording)"
  source_rec="$(read_serve_field "$serve_json" sourceRecording)"
  [[ "$served" != "$source_rec" ]] \
    || die "this work dir serves the source recording directly; start it with --custom-body to get a writable copy"
  edit_bodies "$served" "$target" "$flip_body"
  echo "flipped: hot reload picks this up within $(read_serve_field "$serve_json" reloadInterval)"
  echo "(--fault is startup-only; only mock DATA reloads)"
  exit 0
fi

# --- restore mode -------------------------------------------------------------
if [[ "$restore" == "1" ]]; then
  [[ -n "$work_dir" ]] || die "--restore requires --work-dir"
  [[ -d "$work_dir" ]] || die "--work-dir is not a directory: $work_dir"
  work_dir="$(ql_abs_path "$work_dir")"
  serve_json="$work_dir/serve.json"
  [[ -s "$serve_json" ]] || die "no serve.json in $work_dir; nothing to restore (was --serve used?)"

  old_pid="$(read_serve_field "$serve_json" pid)"
  old_proxy_port="$(read_serve_field "$serve_json" proxyOutPort)"
  old_health_port="$(read_serve_field "$serve_json" healthPort)"
  source_rec="$(read_serve_field "$serve_json" sourceRecording)"
  served="$(read_serve_field "$serve_json" servedRecording)"
  [[ -d "$source_rec" ]] || die "original recording no longer exists: $source_rec"

  echo "stopping faulted mock (pid $old_pid) on proxy port $old_proxy_port"
  ql_stop_pid_and_port "$old_pid" "$old_proxy_port" || die "proxy port $old_proxy_port is still held"

  if [[ "$served" != "$source_rec" && -d "$served" ]]; then
    rm -rf "$served"
    cp -R "$source_rec" "$served"
    echo "restored the pristine recording copy: $served"
  fi

  echo "restarting the mock with no faults: $source_rec"
  "$proxymock_bin" mock \
    --in "$source_rec" \
    --proxy-out-port "$old_proxy_port" \
    --health-port "$old_health_port" \
    --response-selection round-robin \
    --no-out \
    --log-to "$work_dir/mock.log" >/dev/null 2>&1 &
  new_pid=$!
  if ! wait_health "$new_pid" "$old_health_port" || ! wait_port_listening "$old_proxy_port"; then
    ql_stop_pid_and_port "$new_pid" "$old_proxy_port" || true
    ql_die 3 "healthy mock did not come up; see $work_dir/mock.log"
  fi
  python3 - "$serve_json" "$new_pid" "$source_rec" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s.update(pid=int(sys.argv[2]), servedRecording=sys.argv[3], faults=[],
         mockTiming="none", mode="restored")
json.dump(s, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  echo "restored: healthy mock serving on proxy port $old_proxy_port (pid $new_pid)"
  echo "note: --fault is startup-only, so removing a fault means a restart."
  echo "In-flight requests during the swap saw a refused connection."
  exit 0
fi

# --- fault mode ---------------------------------------------------------------
[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$scenario" ]] || die "--scenario is required"
[[ -n "$target" ]] || die "--target is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
case "$scenario" in
  down|ratelimit|garbage|slow|connection|flaky) ;;
  *) die "unknown scenario: $scenario (expected down|ratelimit|garbage|slow|connection|flaky)" ;;
esac
[[ "$retry_after" =~ ^[0-9]+$ ]] || die "--retry-after must be an integer: $retry_after"
[[ -z "$ratio" || "$ratio" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] \
  || die "--ratio must look like F/N (e.g. 1/3); proxymock rejects 0.5 and 50%: $ratio"
[[ -z "$custom_body" || -r "$custom_body" ]] || die "--custom-body file is not readable: $custom_body"

mock_timing="none"
actions=""
case "$scenario" in
  down) actions="status=503" ;;
  ratelimit) actions="status=429,header=Retry-After:$retry_after" ;;
  garbage)
    [[ "$body_fault" =~ ^(corrupt|truncate|truncate:[0-9]+)$ ]] \
      || die "--body-fault must be corrupt, truncate, or truncate:BYTES: $body_fault"
    actions="body=$body_fault" ;;
  connection)
    [[ "$connection" =~ ^(refuse|reset|stall|drop)$ ]] \
      || die "--connection must be refuse|reset|stall|drop: $connection"
    actions="connection=$connection" ;;
  flaky)
    [[ -n "$ratio" ]] || ratio="1/2"
    actions="status=503" ;;
  slow)
    [[ -n "$latency" ]] || die "--scenario slow requires --latency (Go duration with a unit, or Nx)"
    if [[ "$latency" =~ ^[0-9.]+x$ ]]; then
      mock_timing="$latency"
      echo "note: --latency Nx is the GLOBAL --mock-timing multiplier; it slows"
      echo "every mocked endpoint, not just --target. Use a duration like 2500ms"
      echo "for a per-endpoint latency fault."
    elif [[ "$latency" =~ ^[0-9.]+(ns|us|ms|s|m|h)$ ]]; then
      actions="latency=$latency"
    else
      die "--latency must be a Go duration WITH a unit (2500ms, 1.5s) or a multiplier (5x): $latency"
    fi ;;
esac
if [[ -n "$ratio" ]]; then
  if [[ -n "$actions" ]]; then actions="$actions,rate=$ratio"; else actions="rate=$ratio"; fi
fi

# --- pre-check: a fault pattern that matches nothing is a silent no-op --------
# proxymock warns about a no-match pattern itself, but only on its own stdout:
# when it WRAPS an app (`-- your-app`) that output is redirected to
# proxymock.log and never reaches the terminal, so this check stays.
python3 - "$in_dir" "$target" <<'PY' || exit $?
import json, pathlib, re, sys

rec, target = sys.argv[1:3]
try:
    pat = re.compile(target)
except re.error as e:
    print(f"error: --target is not a valid regexp: {e}", file=sys.stderr)
    sys.exit(4)

matched, catalog = set(), set()
for path in sorted(pathlib.Path(rec).rglob("*.md")):
    text = path.read_text(errors="ignore")
    m = re.search(r"json:\s*(\{.*\})", text, re.S)
    if not m:
        continue
    try:
        rr = json.loads(m.group(1))
    except Exception:
        continue
    if rr.get("direction") != "OUT":
        continue
    req = rr.get("http", {}).get("req", {})
    uri = req.get("uri") or ""
    host = (req.get("host") or "").split(":")[0]
    label = f'{req.get("method")} {host}{uri}'
    catalog.add(label)
    if any(pat.search(c) for c in (uri, host + uri)):
        matched.add(label)

if not matched:
    print(f"error: --target {target!r} matched no loaded outbound pair; the "
          "fault would be a SILENT no-op", file=sys.stderr)
    print("remember: the pattern is matched against the bare path and "
          "host+path only - no scheme, no port, no method", file=sys.stderr)
    print("outbound endpoints in this recording:", file=sys.stderr)
    for c in sorted(catalog):
        print(f"  {c}", file=sys.stderr)
    sys.exit(2)

for label in sorted(matched):
    print(f"  matches: {label}")
PY

# --- work dir and optional writable copy --------------------------------------
in_dir="$(ql_abs_path "$in_dir")"
if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-chaos-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(ql_abs_path "$work_dir")"

served_dir="$in_dir"
if [[ -n "$custom_body" ]]; then
  served_dir="$work_dir/recording"
  [[ ! -e "$served_dir" ]] || die "copy dir already exists, pick a fresh --work-dir: $served_dir"
  cp -R "$in_dir" "$served_dir"
  echo "custom body needs an RRPair edit; serving a copy: $served_dir"
  edit_bodies "$served_dir" "$target" "$custom_body"
fi

fault_args=()
if [[ -n "$actions" ]]; then fault_args+=(--fault "${target}:${actions}"); fi

echo ""
echo "=== chaos fault ready ==="
echo "scenario : $scenario"
echo "recording: $served_dir"
if [[ -n "$actions" ]]; then
  echo "fault    : --fault '${target}:${actions}'"
else
  echo "fault    : --mock-timing $mock_timing (global, no per-endpoint fault)"
fi
echo "responses carry 'x-speedscale-chaos: proxymock fault' when a fault fires."

# --- serve --------------------------------------------------------------------
if [[ "$serve" == "1" ]]; then
  [[ -n "$health_port" ]] || health_port="$(ql_pick_port)"
  mock_log="$work_dir/mock.log"
  serve_args=(mock --in "$served_dir"
              --proxy-out-port "$proxy_out_port"
              --health-port "$health_port"
              --response-selection round-robin
              --mock-reload-interval "$reload_interval"
              --no-out --log-to "$mock_log")
  if [[ ${#fault_args[@]} -gt 0 ]]; then serve_args+=("${fault_args[@]}"); fi
  if [[ "$mock_timing" != "none" ]]; then serve_args+=(--mock-timing "$mock_timing"); fi
  echo "starting faulted mock: proxy port $proxy_out_port, health port $health_port"
  "$proxymock_bin" "${serve_args[@]}" >/dev/null 2>&1 &
  mpid=$!
  if ! wait_health "$mpid" "$health_port" || ! wait_port_listening "$proxy_out_port"; then
    ql_stop_pid_and_port "$mpid" "$proxy_out_port" || true
    ql_die 3 "faulted mock did not come up; see $mock_log"
  fi
  python3 - "$work_dir/serve.json" "$mpid" "$proxy_out_port" "$health_port" \
    "$served_dir" "$in_dir" "$mock_timing" "$mock_log" "$reload_interval" \
    "${fault_args[@]:-}" <<'PY'
import json, sys
a = sys.argv
json.dump({
    "pid": int(a[2]),
    "proxyOutPort": int(a[3]),
    "healthPort": int(a[4]),
    "servedRecording": a[5],
    "sourceRecording": a[6],
    "mockTiming": a[7],
    "mockLog": a[8],
    "reloadInterval": a[9],
    "faults": [x for x in a[10:] if x and x != "--fault"],
    "mode": "chaos",
}, open(a[1], "w"), indent=2, sort_keys=True)
PY
  echo "faulted mock serving (pid $mpid); state in $work_dir/serve.json"
  echo ""
  echo "point your app at the mock (proxy env vars):"
  echo "  export http_proxy=http://localhost:${proxy_out_port}"
  echo "  export https_proxy=http://localhost:${proxy_out_port}"
  echo "or probe the mock directly:"
  echo "  curl -x http://localhost:${proxy_out_port} http://<recorded-host>/<recorded-path>"
  echo ""
  echo "to restore the healthy downstream (restart; --fault is startup-only):"
  echo "  $0 --restore --work-dir $work_dir"
else
  echo ""
  echo "serve it yourself:"
  cmd="  proxymock mock --in $served_dir"
  if [[ -n "$actions" ]]; then cmd="$cmd --fault '${target}:${actions}'"; fi
  if [[ "$mock_timing" != "none" ]]; then cmd="$cmd --mock-timing $mock_timing"; fi
  echo "$cmd -- <your app>"
  echo "or rerun with --serve for a standalone faulted mock."
  echo "note: a mock that WRAPS your app restarts the app when it restarts, so"
  echo "recovery scenarios should run the mock un-wrapped (--serve) with the app"
  echo "started separately against the proxy port."
fi
exit 0
