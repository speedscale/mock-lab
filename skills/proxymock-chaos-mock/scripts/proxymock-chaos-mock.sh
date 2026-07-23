#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-chaos-mock.sh --in DIR --scenario NAME --target PATTERN [options]
  proxymock-chaos-mock.sh --restore --work-dir DIR

Build a CHAOS VARIANT of a proxymock recording for one target endpoint (or
endpoint pattern) so the mock lies to your service: slow, erroring,
rate-limiting, garbled, or intermittently failing downstream responses. The
source recording is never touched: everything happens on a copy in the work
dir. After editing, the variant is validated with a mock dry-start, because
one malformed RRPair aborts the ENTIRE mock at load.

Scenarios (--scenario):
  slow       inject latency. '--latency Nx' is a global multiplier (no file
             edits, --target advisory only); '--latency Nms' edits the
             duration metadata of the target pairs and serves with
             --mock-timing recorded (per-endpoint).
  down       rewrite the target pairs' recorded status to 503, body intact.
  ratelimit  status to 429 plus a 'Retry-After: <n>' response header.
  garbage    keep 200, truncate/corrupt the response body.
  flaky      duplicate the target pair into N copies and edit F of them to
             503. Duplicate-signature RRPairs serve round-robin,
             DETERMINISTICALLY, in timestamp order: F/N is an exact,
             periodic failure ratio, not a probability.

Required (build mode):
  --in DIR              Source recording directory (never modified)
  --scenario NAME       One of: slow down ratelimit garbage flaky
  --target PATTERN      Regex matched against the outbound request URI
                        (e.g. '^/v1/projects')

Options:
  --latency VALUE       slow only: 'Nx' multiplier (e.g. 5x, 0.5x) or 'Nms'
                        per-endpoint duration (e.g. 2500ms). Required for slow.
  --ratio F/N           flaky only: F faulty copies out of N (default 1/2)
  --retry-after N       ratelimit only: Retry-After seconds (default 30)
  --work-dir DIR        Where the variant, manifest, and serve state land
                        (default: timestamped dir)
  --serve               Start the chaos mock on the variant after validation
                        and leave it running in the background
  --restore             Stop the chaos mock recorded in --work-dir and
                        restart the mock from the ORIGINAL healthy recording
                        on the same ports (mock data loads once at startup;
                        there is no hot reload, so recovery = restart)
  --proxy-out-port N    Mock proxy port for --serve (default 4140)
  --health-port N       Mock health port for --serve (default: a free port)
  --proxymock PATH      proxymock binary (default: proxymock from PATH)
  -h, --help            Show this help

Exit codes:
  0  variant ready (and serving, if --serve); or restore completed
  2  target endpoint not found in the recording's outbound pairs
  3  variant failed validation: the mock will not load it
  4  precondition or usage failure

Output files (in --work-dir):
  chaos-recording/   the chaos variant (point 'proxymock mock --in' here)
  manifest.json      exactly what changed: scenario, target, files edited,
                     original values, validation result
  validate.log       mock dry-start log from validation
  serve.json         pid/ports of the running mock (only with --serve)
  mock.log           the running mock's log (only with --serve)

Examples:
  # downstream 503s on one endpoint; serve the lying mock
  proxymock-chaos-mock.sh --in ./proxymock/recording \
    --scenario down --target '^/v1/projects' --serve

  # exact 1-in-3 deterministic failures
  proxymock-chaos-mock.sh --in ./proxymock/recording \
    --scenario flaky --target '^/v1/projects' --ratio 1/3 --serve

  # put the healthy downstream back (restart required; no hot reload)
  proxymock-chaos-mock.sh --restore --work-dir ./chaos-work
USAGE
}

# precondition failures use exit 4 per the output contract
die() {
  echo "error: $*" >&2
  exit 4
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

abs_path() {
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

pick_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

in_dir=""
scenario=""
target=""
latency=""
ratio="1/2"
retry_after="30"
work_dir=""
serve="0"
restore="0"
proxy_out_port="4140"
health_port=""
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --scenario) [[ $# -ge 2 ]] || die "--scenario requires a value"; scenario="$2"; shift 2 ;;
    --target) [[ $# -ge 2 ]] || die "--target requires a value"; target="$2"; shift 2 ;;
    --latency) [[ $# -ge 2 ]] || die "--latency requires a value"; latency="$2"; shift 2 ;;
    --ratio) [[ $# -ge 2 ]] || die "--ratio requires a value"; ratio="$2"; shift 2 ;;
    --retry-after) [[ $# -ge 2 ]] || die "--retry-after requires a value"; retry_after="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --serve) serve="1"; shift ;;
    --restore) restore="1"; shift ;;
    --proxy-out-port) [[ $# -ge 2 ]] || die "--proxy-out-port requires a value"; proxy_out_port="$2"; shift 2 ;;
    --health-port) [[ $# -ge 2 ]] || die "--health-port requires a value"; health_port="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

need_cmd python3
need_cmd curl
need_cmd lsof
if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

wait_health() {
  # wait_health PID HEALTH_PORT LOG_FILE -> 0 loaded, 1 failed to load
  local pid="$1" port="$2" log="$3"
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      # one malformed RRPair aborts the entire mock at load: the process
      # exits and the log carries the parse error
      return 1
    fi
    if curl -fsS -m 2 "http://127.0.0.1:${port}/" >/dev/null 2>&1; then
      if grep -q 'failed to read from directories' "$log" 2>/dev/null; then
        return 1
      fi
      return 0
    fi
    sleep 0.25
  done
  return 1
}

stop_mock() {
  # stop_mock PID PORT: SIGTERM, wait, then sweep any survivor on the port
  local pid="$1" port="$2"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  lsof -ti "tcp:${port}" 2>/dev/null | xargs kill 2>/dev/null || true
}

wait_port_free() {
  local port="$1"
  local deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    if [[ -z "$(lsof -ti "tcp:${port}" 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

wait_port_listening() {
  # the health endpoint can report 200 before the outbound proxy port is
  # accepting connections (observed during restore, when the port is being
  # rebound), so wait for the listener explicitly
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

print_instructions() {
  local port="$1" variant="$2" timing="$3"
  echo ""
  echo "point your app at the mock (proxy env vars):"
  echo "  export http_proxy=http://localhost:${port}"
  echo "  export https_proxy=http://localhost:${port}"
  echo "or probe the mock directly:"
  echo "  curl -x http://localhost:${port} http://<recorded-host>/<recorded-path>"
  echo "or wrap your app yourself:"
  if [[ "$timing" == "none" ]]; then
    echo "  proxymock mock --in ${variant} -- <your app>"
  else
    echo "  proxymock mock --in ${variant} --mock-timing ${timing} -- <your app>"
  fi
}

# --- restore mode -------------------------------------------------------------
if [[ "$restore" == "1" ]]; then
  [[ -n "$work_dir" ]] || die "--restore requires --work-dir"
  [[ -d "$work_dir" ]] || die "--work-dir is not a directory: $work_dir"
  work_dir="$(abs_path "$work_dir")"
  serve_json="$work_dir/serve.json"
  [[ -s "$serve_json" ]] || die "no serve.json in $work_dir; nothing to restore (was --serve used?)"

  read -r old_pid old_proxy_port old_health_port source_rec < <(python3 - "$serve_json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(s["pid"], s["proxyOutPort"], s["healthPort"], s["sourceRecording"])
PY
)
  [[ -d "$source_rec" ]] || die "original recording no longer exists: $source_rec"

  echo "stopping chaos mock (pid $old_pid) on proxy port $old_proxy_port"
  stop_mock "$old_pid" "$old_proxy_port"
  wait_port_free "$old_proxy_port" || die "proxy port $old_proxy_port did not free up"

  echo "restarting mock from the healthy recording: $source_rec"
  "$proxymock_bin" mock \
    --in "$source_rec" \
    --proxy-out-port "$old_proxy_port" \
    --health-port "$old_health_port" \
    --no-out \
    --log-to "$work_dir/mock.log" >/dev/null 2>&1 &
  new_pid=$!
  if ! wait_health "$new_pid" "$old_health_port" "$work_dir/mock.log" \
     || ! wait_port_listening "$old_proxy_port"; then
    stop_mock "$new_pid" "$old_proxy_port"
    die "healthy mock did not come up; see $work_dir/mock.log"
  fi
  python3 - "$serve_json" "$new_pid" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["pid"] = int(sys.argv[2])
s["mode"] = "restored"
json.dump(s, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  echo "restored: healthy mock serving on proxy port $old_proxy_port (pid $new_pid)"
  echo "note: mock data loads once at startup; the restart IS the recovery."
  echo "In-flight requests during the swap saw a refused connection."
  exit 0
fi

# --- build mode ---------------------------------------------------------------
[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$scenario" ]] || die "--scenario is required"
[[ -n "$target" ]] || die "--target is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
case "$scenario" in
  slow|down|ratelimit|garbage|flaky) ;;
  *) die "unknown scenario: $scenario (expected slow|down|ratelimit|garbage|flaky)" ;;
esac
if [[ "$scenario" == "slow" ]]; then
  [[ -n "$latency" ]] || die "--scenario slow requires --latency (Nx multiplier or Nms)"
  [[ "$latency" =~ ^[0-9.]+x$ || "$latency" =~ ^[0-9]+ms$ ]] \
    || die "--latency must be a multiplier like 5x or a duration like 2500ms: $latency"
fi
[[ "$ratio" =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] || die "--ratio must look like F/N (e.g. 1/3): $ratio"
[[ "$retry_after" =~ ^[0-9]+$ ]] || die "--retry-after must be an integer: $retry_after"

in_dir="$(abs_path "$in_dir")"
if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-chaos-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"
variant_dir="$work_dir/chaos-recording"
manifest="$work_dir/manifest.json"

if [[ -e "$variant_dir" ]]; then
  die "variant dir already exists, pick a fresh --work-dir: $variant_dir"
fi

echo "copying recording (source is never modified): $in_dir -> $variant_dir"
cp -R "$in_dir" "$variant_dir"

# --- apply the scenario to the copy ------------------------------------------
edit_rc=0
python3 - "$variant_dir" "$scenario" "$target" "$latency" "$ratio" "$retry_after" \
  "$manifest" "$in_dir" <<'PY' || edit_rc=$?
import base64, datetime, json, pathlib, re, os, sys, uuid as uuidlib

(variant_dir, scenario, target, latency, ratio, retry_after,
 manifest_path, source_dir) = sys.argv[1:9]

internal_re = re.compile(r"json:\s*(\{.*\})", re.S)
status_line_re = re.compile(r"(?m)^HTTP/([0-9.]+) (\d+) ([^\n]*)$")

def load(path):
    text = path.read_text(errors="ignore")
    m = internal_re.search(text)
    if not m:
        return text, None
    try:
        return text, json.loads(m.group(1))
    except Exception:
        return text, None

# The RRPair stores the response status in THREE places that must stay
# consistent: the visible status line, the internal '"status":"NNN"', and
# '"statusCode":NNN,"statusMessage":...'. Inconsistent edits or garbage
# status lines make the whole directory fail to load.
def set_status(text, code, message):
    text = status_line_re.sub(
        lambda m: f"HTTP/{m.group(1)} {code} {message}", text, count=1)
    text = re.sub(r'"status":"\d+"', f'"status":"{code}"', text, count=1)
    text = re.sub(r'"statusCode":\d+,"statusMessage":"[^"]*"',
                  f'"statusCode":{code},"statusMessage":"{code} {message}"',
                  text, count=1)
    return text

def add_header(text, name, value):
    # replace an existing header of the same name, else insert after the
    # response status line
    hdr_re = re.compile(rf"(?mi)^{re.escape(name)}: [^\n]*$")
    if hdr_re.search(text):
        return hdr_re.sub(f"{name}: {value}", text, count=1)
    return status_line_re.sub(
        lambda m: m.group(0) + f"\n{name}: {value}", text, count=1)

def set_duration(text, ms):
    return re.sub(r"(?m)^duration: .*$", f"duration: {ms}ms", text, count=1)

def response_body_span(text):
    # the response body is the second fenced block of the RESPONSE section
    resp = text.index("### RESPONSE ###")
    end = text.index("### SIGNATURE ###")
    fences = list(re.finditer(r"(?ms)^```\n(.*?)^```", text[resp:end]))
    if len(fences) != 2:
        return None
    f = fences[1]
    return resp + f.start(1), resp + f.end(1)

def set_garbage_body(text):
    span = response_body_span(text)
    if span is None:
        return None, None
    start, end = span
    original = text[start:end]
    stripped = original.strip()
    if stripped:
        cut = max(16, len(stripped) // 4)
        garbage = stripped[:cut].rstrip() + '"tru'
    else:
        garbage = '{"chaos": "truncat'
    return text[:start] + garbage + "\n" + text[end:], {
        "originalBodyBytes": len(original), "newBody": garbage}

TS_FILE = "%Y-%m-%d_%H-%M-%S.%fZ"
TS_META = "%Y-%m-%dT%H:%M:%S.%fZ"

def duplicate(path, text, rr, offset_us):
    # duplicates need a bumped timestamp (filename + metadata + internal, all
    # consistent) and a FRESH valid uuid: the metadata uuid is parsed
    # strictly and an invalid one aborts the whole directory at load
    ts = datetime.datetime.strptime(rr["ts"], TS_META)
    new_ts = ts + datetime.timedelta(microseconds=offset_us)
    meta_ts, file_ts = new_ts.strftime(TS_META), new_ts.strftime(TS_FILE)
    u = uuidlib.uuid4()
    out = text
    out = re.sub(r"(?m)^ts: .*$", f"ts: {meta_ts}", out, count=1)
    out = out.replace(f'"ts":"{rr["ts"]}"', f'"ts":"{meta_ts}"')
    out = re.sub(r"(?m)^uuid: .*$", f"uuid: {u}", out, count=1)
    out = re.sub(r'"uuid":"[^"]*"',
                 lambda m: f'"uuid":"{base64.b64encode(u.bytes).decode()}"',
                 out, count=1)
    new_path = path.parent / f"{file_ts}.md"
    new_path.write_text(out)
    return new_path

# --- scan outbound pairs and match the target --------------------------------
pat = re.compile(target)
matched, all_out_uris = [], set()
for path in sorted(pathlib.Path(variant_dir).rglob("*.md")):
    text, rr = load(path)
    if rr is None or rr.get("direction") != "OUT":
        continue
    req = rr.get("http", {}).get("req", {})
    uri = req.get("uri") or ""
    all_out_uris.add(f'{req.get("method")} {uri}')
    if pat.search(uri):
        matched.append({"path": path, "text": text, "rr": rr,
                        "uri": uri, "method": req.get("method")})

if not matched:
    print(f"error: --target {target!r} matched no outbound request URIs",
          file=sys.stderr)
    print("outbound endpoints in this recording:", file=sys.stderr)
    for u in sorted(all_out_uris):
        print(f"  {u}", file=sys.stderr)
    sys.exit(2)

edits = []
mock_timing = "none"
params = {}

def record(path, action, original, new):
    edits.append({"file": str(path), "action": action,
                  "original": original, "new": new})

if scenario == "down":
    for m in matched:
        sl = status_line_re.search(m["text"]).group(0)
        m["path"].write_text(set_status(m["text"], 503, "Service Unavailable"))
        record(m["path"], "status", {"statusLine": sl},
               {"statusLine": sl.split(" ")[0] + " 503 Service Unavailable"})

elif scenario == "ratelimit":
    params["retryAfter"] = int(retry_after)
    for m in matched:
        sl = status_line_re.search(m["text"]).group(0)
        out = set_status(m["text"], 429, "Too Many Requests")
        out = add_header(out, "Retry-After", retry_after)
        m["path"].write_text(out)
        record(m["path"], "status+header", {"statusLine": sl},
               {"statusLine": sl.split(" ")[0] + " 429 Too Many Requests",
                "header": f"Retry-After: {retry_after}"})

elif scenario == "garbage":
    for m in matched:
        out, info = set_garbage_body(m["text"])
        if out is None:
            print(f"error: could not locate response body in {m['path']}",
                  file=sys.stderr)
            sys.exit(2)
        m["path"].write_text(out)
        record(m["path"], "body", {"bodyBytes": info["originalBodyBytes"]},
               {"body": info["newBody"]})

elif scenario == "slow":
    params["latency"] = latency
    if latency.endswith("x"):
        # global multiplier: no file edits; timing is a mock flag
        mock_timing = latency
        print("note: --latency Nx is a GLOBAL multiplier applied by "
              "--mock-timing; it slows every mocked endpoint, not just "
              "--target. Use Nms for per-endpoint latency.")
    else:
        mock_timing = "recorded"
        ms = latency[:-2]
        for m in matched:
            orig = re.search(r"(?m)^duration: .*$", m["text"]).group(0)
            m["path"].write_text(set_duration(m["text"], ms))
            record(m["path"], "duration", {"duration": orig},
                   {"duration": f"duration: {ms}ms"})

elif scenario == "flaky":
    faulty, total = (int(x) for x in ratio.split("/"))
    if faulty >= total:
        print(f"error: --ratio F/N needs F < N: {ratio}", file=sys.stderr)
        sys.exit(4)
    params["ratio"] = ratio
    # duplicate-signature RRPairs serve round-robin in timestamp order, so
    # normalize each matched signature group to exactly N copies and edit the
    # first F (earliest timestamps): the failure pattern is periodic and
    # starts with the faults
    groups = {}
    for m in matched:
        key = json.dumps(m["rr"].get("signature", {}), sort_keys=True)
        groups.setdefault(key, []).append(m)
    for group in groups.values():
        group.sort(key=lambda m: m["rr"]["ts"])
        template = group[0]
        for extra in group[total:]:
            extra["path"].unlink()
            record(extra["path"], "remove-surplus-duplicate",
                   {"uri": extra["uri"]}, None)
        group = group[:total]
        offset = 1
        while len(group) < total:
            new_path = duplicate(template["path"], template["text"],
                                 template["rr"], offset)
            record(new_path, "duplicate", {"of": str(template["path"])},
                   {"uri": template["uri"]})
            text, rr = load(new_path)
            group.append({"path": new_path, "text": text, "rr": rr,
                          "uri": template["uri"],
                          "method": template["method"]})
            offset += 1
        group.sort(key=lambda m: m["rr"]["ts"])
        for m in group[:faulty]:
            text, _ = load(m["path"])  # re-read: file may be a fresh duplicate
            sl = status_line_re.search(text).group(0)
            m["path"].write_text(set_status(text, 503, "Service Unavailable"))
            record(m["path"], "status", {"statusLine": sl},
                   {"statusLine": sl.split(" ")[0] + " 503 Service Unavailable"})

# proof-only hook: corrupt the first edited file with the documented failure
# mode (an invalid response line) so the validation gate can be exercised
if os.environ.get("CHAOS_FORCE_BAD_EDIT") == "1" and edits:
    bad = pathlib.Path(edits[0]["file"])
    if bad.exists():
        bad.write_text(status_line_re.sub("XXCHAOS-BAD-EDIT", bad.read_text(),
                                          count=1))

json.dump({
    "scenario": scenario,
    "target": target,
    "sourceRecording": source_dir,
    "variantDir": variant_dir,
    "mockTiming": mock_timing,
    "params": params,
    "matched": [{"file": str(m["path"]), "method": m["method"],
                 "uri": m["uri"]} for m in matched],
    "edits": edits,
    "validation": None,
}, open(manifest_path, "w"), indent=2, sort_keys=True)
print(f"{len(edits)} edit(s) applied for scenario {scenario} "
      f"({len(matched)} matched pair(s))")
PY
if [[ "$edit_rc" -ne 0 ]]; then
  exit "$edit_rc"
fi
mock_timing="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mockTiming"])' "$manifest")"

# --- validate: mock dry-start on the variant ---------------------------------
# Mock data loads once at startup and one malformed RRPair aborts the whole
# directory ("failed to parse response line"), so never declare a variant
# ready without proving the mock loads it.
validate_log="$work_dir/validate.log"
vp="$(pick_port)"
vh="$(pick_port)"
echo "validating: mock dry-start on the variant"
"$proxymock_bin" mock \
  --in "$variant_dir" \
  --proxy-out-port "$vp" \
  --health-port "$vh" \
  --no-out \
  --log-to "$validate_log" >/dev/null 2>&1 &
vpid=$!
loaded="false"
if wait_health "$vpid" "$vh" "$validate_log"; then
  loaded="true"
fi
stop_mock "$vpid" "$vp"

python3 - "$manifest" "$loaded" "$validate_log" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["validation"] = {"loaded": sys.argv[2] == "true", "mockLog": sys.argv[3]}
json.dump(m, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY

if [[ "$loaded" != "true" ]]; then
  echo "FAIL: the mock will not load the chaos variant (the edit broke an RRPair)" >&2
  grep -o 'failed to parse[^"]*' "$validate_log" >&2 || true
  echo "see $validate_log" >&2
  exit 3
fi
echo "validated: mock loads the variant"

# --- serve --------------------------------------------------------------------
if [[ "$serve" == "1" ]]; then
  [[ -n "$health_port" ]] || health_port="$(pick_port)"
  mock_log="$work_dir/mock.log"
  serve_args=(mock --in "$variant_dir"
              --proxy-out-port "$proxy_out_port"
              --health-port "$health_port"
              --no-out --log-to "$mock_log")
  if [[ "$mock_timing" != "none" ]]; then
    serve_args+=(--mock-timing "$mock_timing")
  fi
  echo "starting chaos mock: proxy port $proxy_out_port, health port $health_port"
  "$proxymock_bin" "${serve_args[@]}" >/dev/null 2>&1 &
  mpid=$!
  if ! wait_health "$mpid" "$health_port" "$mock_log" \
     || ! wait_port_listening "$proxy_out_port"; then
    stop_mock "$mpid" "$proxy_out_port"
    die "chaos mock did not come up; see $mock_log"
  fi
  python3 - "$work_dir/serve.json" "$mpid" "$proxy_out_port" "$health_port" \
    "$variant_dir" "$in_dir" "$mock_timing" "$mock_log" <<'PY'
import json, sys
json.dump({
    "pid": int(sys.argv[2]),
    "proxyOutPort": int(sys.argv[3]),
    "healthPort": int(sys.argv[4]),
    "variantDir": sys.argv[5],
    "sourceRecording": sys.argv[6],
    "mockTiming": sys.argv[7],
    "mockLog": sys.argv[8],
    "mode": "chaos",
}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
  echo "chaos mock serving (pid $mpid); state in $work_dir/serve.json"
fi

echo ""
echo "=== chaos variant ready ==="
echo "scenario : $scenario (target: $target)"
echo "variant  : $variant_dir"
echo "manifest : $manifest"
if [[ "$serve" == "1" ]]; then
  print_instructions "$proxy_out_port" "$variant_dir" "$mock_timing"
  echo ""
  echo "to restore the healthy downstream (restart; no hot reload):"
  echo "  $0 --restore --work-dir $work_dir"
else
  echo "serve it with:"
  if [[ "$mock_timing" == "none" ]]; then
    echo "  proxymock mock --in $variant_dir -- <your app>"
  else
    echo "  proxymock mock --in $variant_dir --mock-timing $mock_timing -- <your app>"
  fi
  echo "or rerun with --serve for a standalone chaos mock."
fi
exit 0
