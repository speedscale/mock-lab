#!/usr/bin/env bash
# Record the storefront with the payment and order fixture running.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recorded-local}
app_port=${PORT:-8080}
fixture_pid=
recorder_pid=

cleanup() {
  if [[ -n "$recorder_pid" ]]; then kill -INT "$recorder_pid" 2>/dev/null || true; wait "$recorder_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT

if [[ -e "$recording_dir" ]]; then
  echo "capture output already exists: $recording_dir; choose a fresh RECORDING_DIR" >&2
  exit 1
fi

cd "$root_dir"
mkdir -p .bin
go build -o .bin/fixture ./fixture
go build -o .bin/storefront .

.bin/fixture &
fixture_pid=$!
for _ in $(seq 1 15); do
  curl --fail --silent http://localhost:8091/healthz >/dev/null 2>&1 && curl --fail --silent http://localhost:8092/healthz >/dev/null 2>&1 && break
  sleep 1
done

PORT="$app_port" "$proxymock" record --app-port "$app_port" --out "$recording_dir" -- .bin/storefront &
recorder_pid=$!
for _ in $(seq 1 30); do
  curl --fail --silent "http://localhost:$app_port/healthz" >/dev/null 2>&1 && break
  sleep 1
done
sleep 1

# Go through proxymock's inbound port so both directions are recorded.
scripts/traffic.sh http://localhost:4143
sleep 2

kill -INT "$recorder_pid" 2>/dev/null || true
wait "$recorder_pid" || true
recorder_pid=

echo "Recorded $(find "$recording_dir" -name '*.md' | wc -l | tr -d ' ') request/response files under $recording_dir"
