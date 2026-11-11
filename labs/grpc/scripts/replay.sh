#!/usr/bin/env bash
# Replay the recorded client calls against the orders service, with its
# Pub/Sub and OTLP dependencies answered from the recording by proxymock mock.
# Nothing else needs to run and no network is used:
#
#   proxymock replay ──► :9090 orders ──► :18085 proxymock mock (Pub/Sub, recorded)
#                                     └─► :14317 proxymock mock (OTLP, recorded)
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-proxymock/recording}
results_dir=${RESULTS_DIR:-proxymock/results}
log_dir=$root_dir/.run
pids=()

cd "$root_dir"
mkdir -p "$log_dir"

cleanup() {
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

rm -rf "$results_dir/mocked" "$results_dir/replay"
"$proxymock" mock --in "$recording_dir" --out "$results_dir/mocked" \
  --map 18085=localhost:8085 --map 14317=localhost:4317 >"$log_dir/mock.log" 2>&1 &
pids+=($!)
wait_for_port 18085 "$!" "$log_dir/mock.log"
wait_for_port 14317 "$!" "$log_dir/mock.log"

PORT=9090 PUBSUB_ADDR=localhost:18085 OTLP_ADDR=localhost:14317 ./bin/orders >"$log_dir/orders.log" 2>&1 &
pids+=($!)
wait_for_port 9090 "$!" "$log_dir/orders.log"

"$proxymock" replay --in "$recording_dir" --test-against localhost:9090 --out "$results_dir/replay"
