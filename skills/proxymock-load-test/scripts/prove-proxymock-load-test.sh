#!/usr/bin/env bash
# Proves: a multi-VU load test runs against the mock-lab app (downstream mocked
# from the committed recording) and produces real throughput with no failures.
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
load_script="$script_dir/proxymock-load-test.sh"

need_cmd curl
need_cmd go
need_cmd proxymock
need_cmd python3
[[ -x "$load_script" ]] || die "load-test script is not executable: $load_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-load-test-proof.$$"
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

app_port="$(pick_port)"
out_port="$(pick_port)"
health_port="$(pick_port)"

echo "starting mock-lab Go app with downstream mocked from the recording"
( cd "$repo_root/go" && PORT="$app_port" \
    proxymock mock \
      --in "$recording" \
      --proxy-out-port "$out_port" \
      --health-port "$health_port" \
      -- go run . ) >"$tmp/mock.log" 2>&1 &
pids+=("$!")

wait_url "http://127.0.0.1:${app_port}/" || die "app under proxymock mock did not start; see $tmp/mock.log"

echo "running multi-VU load test"
"$load_script" \
  --in "$recording/localhost" \
  --test-against "http://127.0.0.1:${app_port}" \
  --vus 6 --for 8s \
  --work-dir "$tmp/load" \
  --fail-if 'requests.failed!=0' >"$tmp/load.out" 2>&1 || {
    cat "$tmp/load.out" >&2
    die "load test exited nonzero"
  }
cat "$tmp/load.out"

python3 - "$tmp/load/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
total = s.get("totalRequests") or 0
failed = s.get("failed")
rps = s.get("rps") or 0
p99 = (s.get("latencyMs") or {}).get("p99")
if total < 20:
    raise SystemExit(f"too few requests for a load test: {total}")
if failed != 0:
    raise SystemExit(f"load test had failures: {failed}")
if not rps or rps <= 0:
    raise SystemExit(f"no measured throughput: rps={rps}")
if p99 is None:
    raise SystemExit("latency percentiles missing from summary")
print(f"PASS: total={total} failed={failed} rps={rps:.1f} p99={p99}ms")
PY
