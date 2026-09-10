#!/usr/bin/env bash
# Proves: replay tuning improves a real mock-lab recording, not a one-request fixture.
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
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$skill_dir/../.." && pwd)"
tune_script="$script_dir/tune-proxymock-replay.sh"

need_cmd curl
need_cmd go
need_cmd proxymock
need_cmd python3
[[ -x "$tune_script" ]] || die "tuning script is not executable: $tune_script"

tmp="${TMPDIR:-/tmp}/proxymock-replay-tuning-proof.$$"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT

mkdir -p "$tmp"

downstream_port="$(pick_port)"
app_port="$(pick_port)"
map_port="$(pick_port)"
proxy_in_port="$(pick_port)"
proxy_out_port="$(pick_port)"
record_health_port="$(pick_port)"

recording="$tmp/recording"
replay_traffic="$tmp/replay-traffic"
tuned_mock="$tmp/tuned-mock"
stale_mock="$tmp/stale-mock"
before_dir="$tmp/before"
after_dir="$tmp/after"
inbound_json="$tmp/inbound-coverage.json"
report_json="$tmp/proof-summary.json"

echo "starting local CNCF downstream API"
(cd "$repo_root/lab/server" && PORT="$downstream_port" go run . >"$tmp/downstream.log" 2>&1) &
pids+=("$!")
wait_url "http://127.0.0.1:${downstream_port}/healthz" || die "downstream API did not start; see $tmp/downstream.log"

app_runner="$tmp/run-go-app.sh"
cat >"$app_runner" <<EOF
#!/usr/bin/env bash
cd "$repo_root/languages/go"
exec go run .
EOF
chmod +x "$app_runner"

echo "recording mock-lab Go app traffic through proxymock"
PORT="$app_port" DOWNSTREAM_URL="http://127.0.0.1:${map_port}" \
  proxymock record \
    --out "$recording" \
    --app-port "$app_port" \
    --proxy-in-port "$proxy_in_port" \
    --proxy-out-port "$proxy_out_port" \
    --health-port "$record_health_port" \
    --map "${map_port}=http://127.0.0.1:${downstream_port}" \
    --app-health-endpoint "http://127.0.0.1:${app_port}/" \
    -- "$app_runner" >"$tmp/record.log" 2>&1 &
pids+=("$!")

wait_url "http://127.0.0.1:${proxy_in_port}/" || die "proxymock record/app did not start; see $tmp/record.log"

mapfile -t project_ids < <(python3 - "$repo_root/lab/server/data/projects.json" <<'PY'
import json
import sys

projects = json.load(open(sys.argv[1]))
for project in projects[:8]:
    print(project["id"])
PY
)

paths=("/" "/api/projects" "/api/categories" "/api/stats")
for id in "${project_ids[@]}"; do
  paths+=("/api/projects/${id}")
done

echo "driving ${#paths[@]} real app requests"
for path in "${paths[@]}"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${proxy_in_port}${path}")"
  [[ "$code" == "200" ]] || die "app request failed: $path returned $code"
done

echo "driving auth/order flow"
token="$(curl -sS -X POST "http://127.0.0.1:${proxy_in_port}/oauth/token" \
  | grep -o '"access_token": *"[^"]*"' | sed 's/.*"access_token": *"//;s/"$//')"
[[ -n "$token" ]] || die "auth flow failed: no access_token"

order_id="$(curl -sS -X POST "http://127.0.0.1:${proxy_in_port}/api/orders" \
  -H "Authorization: Bearer ${token}" \
  -H 'Content-Type: application/json' \
  -d '{"project":"kubernetes"}' \
  | grep -o '"order_id": *"[^"]*"' | sed 's/.*"order_id": *"//;s/"$//')"
[[ -n "$order_id" ]] || die "auth flow failed: no order_id"

code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${proxy_in_port}/api/orders/${order_id}" \
  -H "Authorization: Bearer ${token}")"
[[ "$code" == "200" ]] || die "auth flow failed: get order returned $code"

sleep 1
for pid in "${pids[@]}"; do
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
done
pids=()

echo "extracting outbound dependency traffic"
python3 - "$recording" "$replay_traffic" "$tuned_mock" "$downstream_port" "$inbound_json" <<'PY'
import json
import pathlib
import re
import shutil
import sys

src = pathlib.Path(sys.argv[1])
replay_dst = pathlib.Path(sys.argv[2])
mock_dst = pathlib.Path(sys.argv[3])
downstream_port = int(sys.argv[4])
inbound_json = pathlib.Path(sys.argv[5])
internal_re = re.compile(r"json:\s*(\{.*\})", re.S)
count = 0
inbound = []
required = {
    ("GET", "/"),
    ("GET", "/api/projects"),
    ("GET", "/api/categories"),
    ("GET", "/api/stats"),
    ("POST", "/oauth/token"),
    ("POST", "/api/orders"),
}
seen = set()
seen_project_detail = False
seen_order_detail = False

for path in sorted(src.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    text = path.read_text(errors="ignore")
    try:
        if path.suffix == ".json":
            rr = json.loads(text)
        else:
            match = internal_re.search(text)
            if not match:
                continue
            rr = json.loads(match.group(1))
    except Exception:
        continue

    req = rr.get("http", {}).get("req", {})
    upstream = rr.get("netinfo", {}).get("upstream", {})
    method = req.get("method") or rr.get("command") or ""
    uri = req.get("uri") or rr.get("location") or ""

    if rr.get("direction") == "IN":
        inbound.append({"method": method, "uri": uri})
        seen.add((method, uri))
        if method == "GET" and uri.startswith("/api/projects/"):
            seen_project_detail = True
        if method == "GET" and uri.startswith("/api/orders/"):
            seen_order_detail = True

    if rr.get("direction") != "OUT" or not uri.startswith("/v1/"):
        continue
    if int(upstream.get("port") or 0) != downstream_port:
        continue

    rel = path.relative_to(src)
    for dst in (replay_dst, mock_dst):
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, out)
    count += 1

print(count)
missing = sorted(f"{method} {uri}" for method, uri in required - seen)
if not seen_project_detail:
    missing.append("GET /api/projects/{id}")
if not seen_order_detail:
    missing.append("GET /api/orders/{order_id}")
coverage = {
    "inboundRequestCount": len(inbound),
    "requiredRoutesCovered": not missing,
    "missingRoutes": missing,
    "observedRoutes": inbound,
}
inbound_json.write_text(json.dumps(coverage, indent=2, sort_keys=True) + "\n")
if missing:
    raise SystemExit("missing inbound route coverage: " + ", ".join(missing))
if count < 10:
    raise SystemExit(f"expected at least 10 outbound RRPairs, got {count}")
PY

cp -R "$tuned_mock" "$stale_mock"

echo "creating stale mock set with missing dependency recordings"
removed="$(python3 - "$stale_mock" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
internal_re = re.compile(r"json:\s*(\{.*\})", re.S)
removed = 0

for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    text = path.read_text(errors="ignore")
    match = internal_re.search(text)
    if not match:
        continue
    rr = json.loads(match.group(1))
    uri = rr.get("http", {}).get("req", {}).get("uri", "")
    if not (uri.startswith("/v1/project/") or uri == "/v1/categories"):
        continue

    path.unlink()
    removed += 1

print(removed)
if removed < 5:
    raise SystemExit(f"expected to remove at least 5 stale recordings, got {removed}")
PY
)"

# _TUNE_MOCK_DIR / _TUNE_REPLAY_DIR are the tune script's internal hook for
# serving one mock set while replaying a different (full) recording. This is the
# only place mock and replay differ; users tune a single recording with --in.
echo "measuring stale mock baseline"
_TUNE_MOCK_DIR="$stale_mock" _TUNE_REPLAY_DIR="$replay_traffic" "$tune_script" \
  --work-dir "$before_dir" \
  --proxy-port "$(pick_port)" \
  --health-port "$(pick_port)" >/dev/null

echo "measuring tuned mock set"
_TUNE_MOCK_DIR="$tuned_mock" _TUNE_REPLAY_DIR="$replay_traffic" "$tune_script" \
  --work-dir "$after_dir" \
  --proxy-port "$(pick_port)" \
  --health-port "$(pick_port)" \
  --fail-under 95 >/dev/null

python3 - "$before_dir/summary.json" "$after_dir/summary.json" "$report_json" "$removed" "$inbound_json" <<'PY'
import json
import pathlib
import sys

before_path = pathlib.Path(sys.argv[1])
after_path = pathlib.Path(sys.argv[2])
report_path = pathlib.Path(sys.argv[3])
removed = int(sys.argv[4])
inbound_path = pathlib.Path(sys.argv[5])
before = json.loads(before_path.read_text())
after = json.loads(after_path.read_text())
inbound = json.loads(inbound_path.read_text())

report = {
    "inbound": inbound,
    "trafficFiles": before["replayInputRRPairs"],
    "removedMockFiles": removed,
    "before": {
        "hitRate": before["hitRate"],
        "hits": before["hits"],
        "misses": before["misses"],
        "observedMockRequests": before["observedMockRequests"],
        "summary": str(before_path),
    },
    "after": {
        "hitRate": after["hitRate"],
        "hits": after["hits"],
        "misses": after["misses"],
        "observedMockRequests": after["observedMockRequests"],
        "summary": str(after_path),
    },
}
report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

if report["trafficFiles"] < 10:
    raise SystemExit(f"too little traffic: {report['trafficFiles']} files")
if before["misses"] < 5:
    raise SystemExit(f"baseline did not produce enough misses: {before['misses']}")
if before["hitRate"] >= after["hitRate"]:
    raise SystemExit(f"hit rate did not improve: before={before['hitRate']} after={after['hitRate']}")
if after["hitRate"] < 95:
    raise SystemExit(f"tuned hit rate too low: {after['hitRate']}")

print(
    "PASS: "
    f"traffic={report['trafficFiles']} "
    f"inbound={inbound['inboundRequestCount']} "
    f"before={before['hitRate']:.2f}%/{before['misses']}miss "
    f"after={after['hitRate']:.2f}%/{after['misses']}miss "
    f"report={report_path}"
)
PY
