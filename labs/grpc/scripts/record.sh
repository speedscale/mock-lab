#!/usr/bin/env bash
# Record the orders service: inbound calls from the client, and its outbound
# Pub/Sub and OTLP calls through proxymock's --map reverse proxies.
#
#   client ──► :4143 proxymock ──► :9090 orders ──► :18085 proxymock ──► :8085 pubsub-fake
#                                               └─► :14317 proxymock ──► :4317 otlp-collector
#
# The orders service connects to the mapped ports directly, so no proxy
# environment variables are needed and nothing leaves this machine.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-proxymock/recording}
log_dir=$root_dir/.run
pids=()

cd "$root_dir"
mkdir -p "$log_dir"

cleanup() {
  # stop in reverse order: orders first, so it flushes its last spans and
  # Pub/Sub messages through the recorder before the recorder stops
  for (( i=${#pids[@]}-1; i>=0; i-- )); do
    kill -INT "${pids[$i]}" 2>/dev/null || true
    wait "${pids[$i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT INT TERM

wait_for_port() {
  local port=$1 pid=$2 log=$3
  for _ in $(seq 1 40); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log" >&2
      exit 1
    fi
    sleep 0.25
  done
  echo "nothing is listening on port $port; see $log" >&2
  exit 1
}

PORT=8085 ./bin/pubsub-fake >"$log_dir/pubsub-fake.log" 2>&1 &
pids+=($!)
wait_for_port 8085 "$!" "$log_dir/pubsub-fake.log"

PORT=4317 ./bin/otlp-collector >"$log_dir/otlp-collector.log" 2>&1 &
pids+=($!)
wait_for_port 4317 "$!" "$log_dir/otlp-collector.log"

rm -rf "$recording_dir"
"$proxymock" record --app-port 9090 --out "$recording_dir" \
  --map 18085=localhost:8085 --map 14317=localhost:4317 >"$log_dir/proxymock.log" 2>&1 &
pids+=($!)
wait_for_port 4143 "$!" "$log_dir/proxymock.log"
wait_for_port 18085 "$!" "$log_dir/proxymock.log"
wait_for_port 14317 "$!" "$log_dir/proxymock.log"

PORT=9090 PUBSUB_ADDR=localhost:18085 OTLP_ADDR=localhost:14317 ./bin/orders >"$log_dir/orders.log" 2>&1 &
pids+=($!)
wait_for_port 9090 "$!" "$log_dir/orders.log"

./bin/client -addr localhost:4143

cleanup
pids=()
echo "Recorded $(find "$recording_dir" -name '*.md' | wc -l | tr -d ' ') calls in $recording_dir:"
find "$recording_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | sed 's/^/  /'
