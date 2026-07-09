#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tune-proxymock-replay.sh --in DIR [options]

Required:
  --in DIR                Recording to tune. Serves as both the mock set and the
                          replay set: outbound (direction OUT) pairs are replayed
                          against the mock; inbound (direction IN) pairs are
                          skipped automatically.

Options:
  --work-dir DIR          Directory for logs, observed RRPairs, and summary.json
  --proxymock PATH        proxymock binary (default: proxymock from PATH)
  --proxy-port PORT       proxymock outbound proxy port (default: 4140)
  --health-port PORT      proxymock health port (default: dynamic)
  --fail-under PERCENT    Exit nonzero when hit rate is below PERCENT
  --mock-arg ARG          Extra argument for proxymock mock; repeatable
  -h, --help              Show this help

Examples:
  tune-proxymock-replay.sh --in ./recording
  tune-proxymock-replay.sh --in ./recording --fail-under 95
  tune-proxymock-replay.sh --in ./recording \
    --mock-arg '--map=15432=postgres://localhost:5432'
USAGE
}

die() {
  echo "error: $*" >&2
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

count_rrpairs() {
  local dir="$1"
  find "$dir" -path '*/.git/*' -prune -o \
    -type f \( -name '*.md' -o -name '*.json' \) -print | wc -l | tr -d ' '
}

wait_ready() {
  local port="$1"
  local pid="$2"
  local deadline=$((SECONDS + 30))
  local urls=(
    "http://127.0.0.1:${port}/speedscale/ready"
    "http://127.0.0.1:${port}/ready"
    "http://127.0.0.1:${port}/health"
  )

  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    for url in "${urls[@]}"; do
      if curl -fsS "$url" >/dev/null 2>&1; then
        return 0
      fi
    done
    sleep 0.25
  done

  return 1
}

in_dir=""
# Internal hook for prove-proxymock-replay-tuning.sh only: it must serve a stale
# mock set while replaying the full recording, which is the only case where mock
# and replay differ. Not a user-facing option; the CLI is --in.
mock_in="${_TUNE_MOCK_DIR:-}"
replay_in="${_TUNE_REPLAY_DIR:-}"
work_dir=""
proxymock_bin="${PROXYMOCK:-proxymock}"
proxy_port="4140"
health_port="0"
fail_under=""
mock_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)
      [[ $# -ge 2 ]] || die "--in requires a value"
      in_dir="$2"
      shift 2
      ;;
    --work-dir)
      [[ $# -ge 2 ]] || die "--work-dir requires a value"
      work_dir="$2"
      shift 2
      ;;
    --proxymock)
      [[ $# -ge 2 ]] || die "--proxymock requires a value"
      proxymock_bin="$2"
      shift 2
      ;;
    --proxy-port)
      [[ $# -ge 2 ]] || die "--proxy-port requires a value"
      proxy_port="$2"
      shift 2
      ;;
    --health-port)
      [[ $# -ge 2 ]] || die "--health-port requires a value"
      health_port="$2"
      shift 2
      ;;
    --fail-under)
      [[ $# -ge 2 ]] || die "--fail-under requires a value"
      fail_under="$2"
      shift 2
      ;;
    --mock-arg)
      [[ $# -ge 2 ]] || die "--mock-arg requires a value"
      mock_args+=("$2")
      shift 2
      ;;
    --replay-arg)
      die "--replay-arg is not supported; this script sends replay RRPair requests directly"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# --in seeds both the mock set and the replay set.
mock_in="${mock_in:-$in_dir}"
replay_in="${replay_in:-$in_dir}"
[[ -n "$mock_in" && -n "$replay_in" ]] || die "--in is required"
[[ -d "$mock_in" ]] || die "not a directory: $mock_in"
[[ -d "$replay_in" ]] || die "not a directory: $replay_in"

need_cmd python3
need_cmd curl

if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

if [[ "$health_port" == "0" ]]; then
  health_port="$(pick_port)"
fi

mock_in="$(abs_path "$mock_in")"
replay_in="$(abs_path "$replay_in")"

if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-tuning-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"

mock_out="$work_dir/mock-output"
mock_log="$work_dir/mock.log"
replay_log="$work_dir/replay.log"
summary_json="$work_dir/summary.json"

mkdir -p "$mock_out"

mock_input_total="$(count_rrpairs "$mock_in")"
replay_input_total="$(count_rrpairs "$replay_in")"
[[ "$mock_input_total" -gt 0 ]] || die "no RRPair .md or .json files found in the mock set: $mock_in"
[[ "$replay_input_total" -gt 0 ]] || die "no RRPair .md or .json files found in the replay set: $replay_in"

mock_pid=""
cleanup() {
  if [[ -n "$mock_pid" ]] && kill -0 "$mock_pid" 2>/dev/null; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "starting proxymock mock on proxy port ${proxy_port}"
"$proxymock_bin" mock \
  --in "$mock_in" \
  --out "$mock_out" \
  --proxy-out-port "$proxy_port" \
  --health-port "$health_port" \
  --no-passthrough \
  "${mock_args[@]}" >"$mock_log" 2>&1 &
mock_pid="$!"

if ! wait_ready "$health_port" "$mock_pid"; then
  echo "proxymock mock did not become ready; see $mock_log" >&2
  exit 1
fi

echo "sending replay traffic through proxymock"
replay_rc=0
python3 - "$replay_in" "$proxy_port" "$replay_log" <<'PY' || replay_rc=$?
import base64
import json
import pathlib
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

root = pathlib.Path(sys.argv[1])
proxy_port = sys.argv[2]
log_path = pathlib.Path(sys.argv[3])
proxy = f"http://127.0.0.1:{proxy_port}"
internal_re = re.compile(r"json:\s*(\{.*\})", re.S)
sent = 0
failed = 0
skipped = 0

# Some platforms bypass proxies for .local or loopback-like hostnames even when
# a proxy is explicitly configured. Replay tuning must preserve recorded hosts
# and always send through proxymock.
urllib.request.proxy_bypass = lambda host: False

# HTTPS pairs are replayed through the local proxymock mock, which terminates TLS
# with its own MITM cert. This client has no reason to trust that CA, so skip
# verification: the tuner only measures signature matches, and the connection
# never leaves the loopback proxy.
tls_ctx = ssl.create_default_context()
tls_ctx.check_hostname = False
tls_ctx.verify_mode = ssl.CERT_NONE

opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({"http": proxy, "https": proxy}),
    urllib.request.HTTPSHandler(context=tls_ctx),
)

def decode_value(v):
    if not v:
        return ""
    try:
        return base64.b64decode(v).decode()
    except Exception:
        return ""

def load_rr(path):
    text = path.read_text(errors="ignore")
    if path.suffix == ".json":
        return json.loads(text)
    match = internal_re.search(text)
    if not match:
        raise ValueError("missing INTERNAL json block")
    return json.loads(match.group(1))

def request_url(rr):
    req = rr.get("http", {}).get("req", {})
    if not req:
        return ""
    raw_url = req.get("url", "")
    if raw_url.startswith("http://") or raw_url.startswith("https://"):
        return raw_url

    host = req.get("host", "")
    uri = req.get("uri") or raw_url or rr.get("location", "")
    if not host or not uri:
        sig = rr.get("signature", {})
        host = host or decode_value(sig.get("http:host", ""))
        uri = uri or decode_value(sig.get("http:url", ""))
    if not host or not uri:
        return ""

    upstream = rr.get("netinfo", {}).get("upstream", {})
    port = int(upstream.get("port") or 0)
    scheme = "https" if rr.get("l7protocol", "").lower() == "https" or port == 443 else "http"
    if ":" not in host and port and port not in (80, 443):
        host = f"{host}:{port}"
    return f"{scheme}://{host}{uri}"

def request_body(rr):
    req = rr.get("http", {}).get("req", {})
    for key in ("bodyBase64", "bodyb64", "contentBase64"):
        if req.get(key):
            try:
                return base64.b64decode(req[key])
            except Exception:
                return None
    for key in ("body", "content"):
        value = req.get(key)
        if isinstance(value, str) and value:
            return value.encode()
    return None

def request_headers(rr):
    req = rr.get("http", {}).get("req", {})
    headers = req.get("headers", {})
    if not isinstance(headers, dict):
        return {}
    out = {}
    for name, value in headers.items():
        if isinstance(value, list):
            value = ",".join(str(v) for v in value)
        out[str(name)] = str(value)
    return out

with log_path.open("w") as log:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in {".md", ".json"}:
            continue
        try:
            rr = load_rr(path)
            # Inbound pairs are requests the app received, not calls it made;
            # replaying them would fire at the mock proxy with no app behind it.
            # Only outbound (direction OUT) pairs belong in a replay.
            if str(rr.get("direction", "")).upper() == "IN":
                skipped += 1
                print(json.dumps({"file": str(path), "status": "skipped", "reason": "inbound pair"}), file=log)
                continue
            req = rr.get("http", {}).get("req", {})
            method = req.get("method") or rr.get("command") or "GET"
            url = request_url(rr)
            if not url:
                skipped += 1
                print(json.dumps({"file": str(path), "status": "skipped", "reason": "missing http request"}), file=log)
                continue
            body = request_body(rr)
            request = urllib.request.Request(url, data=body, method=method)
            for name, value in request_headers(rr).items():
                if name.lower() not in {"host", "content-length"}:
                    request.add_header(name, value)
            if not request.has_header("User-agent"):
                request.add_header("User-Agent", "proxymock-replay-tuning/1.0")
            with opener.open(request, timeout=15) as response:
                response.read()
            sent += 1
            print(json.dumps({"file": str(path), "status": "sent", "method": method, "url": url}), file=log)
        except urllib.error.HTTPError as e:
            e.read()
            sent += 1
            print(json.dumps({"file": str(path), "status": "sent", "code": e.code}), file=log)
        except Exception as e:
            failed += 1
            print(json.dumps({"file": str(path), "status": "failed", "error": str(e)}), file=log)

    print(json.dumps({"sent": sent, "failed": failed, "skipped": skipped}), file=log)

if sent == 0:
    print("no replayable HTTP RRPair requests found", file=sys.stderr)
    sys.exit(2)
if failed:
    sys.exit(1)

time.sleep(0.5)
PY

cleanup
trap - EXIT

summary_rc=0
python3 - "$mock_out" "$replay_log" "$summary_json" "$mock_input_total" "$replay_input_total" "$mock_log" <<'PY' || summary_rc=$?
import json
import pathlib
import re
import sys

mock_out = pathlib.Path(sys.argv[1])
replay_log = pathlib.Path(sys.argv[2])
summary_json = pathlib.Path(sys.argv[3])
mock_input_total = int(sys.argv[4])
replay_input_total = int(sys.argv[5])
mock_log = pathlib.Path(sys.argv[6])

match_re = re.compile(r"\bmatch=([A-Za-z_-]+)\b")
counts = {}
files = {}

for path in sorted(mock_out.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    try:
        text = path.read_text(errors="ignore")
    except OSError:
        continue
    found = False
    if path.suffix == ".json":
        try:
            raw = json.loads(text).get("tags", {}).get("match", "")
        except Exception:
            raw = ""
        if raw:
            found = True
            key = raw.upper().replace("-", "_")
            counts[key] = counts.get(key, 0) + 1
            files.setdefault(key, []).append(str(path))
    else:
        for raw in match_re.findall(text):
            found = True
            key = raw.upper().replace("-", "_")
            counts[key] = counts.get(key, 0) + 1
            files.setdefault(key, []).append(str(path))
    if not found:
        counts["UNKNOWN"] = counts.get("UNKNOWN", 0) + 1
        files.setdefault("UNKNOWN", []).append(str(path))

hits = counts.get("HIT", 0)
misses = counts.get("MISS", 0) + counts.get("NO_MATCH", 0) + counts.get("FAIL", 0)
passthroughs = counts.get("PASSTHROUGH", 0) + counts.get("PASS", 0)
observed = sum(counts.values())
hit_rate = round((hits / observed) * 100, 2) if observed else 0.0

replay_json = None
try:
    for line in replay_log.read_text(errors="ignore").splitlines():
        parsed = json.loads(line)
        if {"sent", "failed", "skipped"} <= set(parsed):
            replay_json = parsed
except Exception:
    replay_json = None

summary = {
    "hitRate": hit_rate,
    "observedMockRequests": observed,
    "hits": hits,
    "misses": misses,
    "passthroughs": passthroughs,
    "matchCounts": counts,
    "mockInputRRPairs": mock_input_total,
    "replayInputRRPairs": replay_input_total,
    "artifacts": {
        "mockOutput": str(mock_out),
        "mockLog": str(mock_log),
        "replayLog": str(replay_log),
    },
    "missFiles": files.get("MISS", []) + files.get("NO_MATCH", []) + files.get("FAIL", []),
    "passthroughFiles": files.get("PASSTHROUGH", []) + files.get("PASS", []),
}

if replay_json is not None:
    summary["replay"] = replay_json

summary_json.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
print(json.dumps(summary, indent=2, sort_keys=True))

if observed == 0:
    print("no user replay traffic was observed by proxymock mock", file=sys.stderr)
    sys.exit(2)
PY

echo "summary: $summary_json"

if [[ "$summary_rc" -ne 0 ]]; then
  exit "$summary_rc"
fi

if [[ "$replay_rc" -ne 0 ]]; then
  echo "replay request sending exited with status $replay_rc; see $replay_log" >&2
  exit "$replay_rc"
fi

if [[ -n "$fail_under" ]]; then
  python3 - "$summary_json" "$fail_under" <<'PY'
import json
import sys

summary = json.load(open(sys.argv[1]))
threshold = float(sys.argv[2])
actual = float(summary["hitRate"])
if actual < threshold:
    print(f"hit rate {actual:.2f}% is below threshold {threshold:.2f}%", file=sys.stderr)
    sys.exit(1)
PY
fi
