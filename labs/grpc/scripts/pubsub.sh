#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
proxymock=${PROXYMOCK:-proxymock}
recording=${PUBSUB_RECORDING:-proxymock/results/pubsub/recorded}
mkdir -p .run
run_dir=$(mktemp -d .run/pubsub.XXXXXX)
pids=()

cleanup() {
  for (( i=${#pids[@]}-1; i>=0; i-- )); do
    kill -TERM "${pids[$i]}" 2>/dev/null || true
    wait "${pids[$i]}" 2>/dev/null || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for_port() {
  local port=$1 pid=$2 log=$3
  for _ in {1..60}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log" >&2
      return 1
    fi
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo "Timed out waiting for port $port. See $log." >&2
  return 1
}

start_broker() {
  HOST=127.0.0.1 PORT=8085 ./bin/pubsub-fake >"$run_dir/broker.log" 2>&1 &
  pids+=("$!")
  wait_for_port 8085 "$!" "$run_dir/broker.log"
  ./bin/pubsub-worker setup
}

start_worker() {
  local addr=$1
  ./bin/pubsub-worker -addr "$addr" consume >"$run_dir/worker.log" 2>&1 &
  worker=$!
  pids+=("$worker")
  for _ in {1..60}; do
    if grep -q '^StreamingPull opened$' "$run_dir/worker.log"; then
      return 0
    fi
    if ! kill -0 "$worker" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  cat "$run_dir/worker.log" >&2
  return 1
}

finish_worker() {
  local status=0
  wait "$worker" || status=$?
  cat "$run_dir/worker.log"
  return "$status"
}

case "${1:-}" in
  record)
    if [[ -e "$recording" ]]; then
      echo "Recording already exists. Set PUBSUB_RECORDING to a fresh directory to capture again." >&2
      exit 1
    fi
    start_broker
    "$proxymock" record --out "$recording" --map 18085=localhost:8085 >"$run_dir/record.log" 2>&1 &
    recorder=$!
    pids+=("$recorder")
    wait_for_port 18085 "$recorder" "$run_dir/record.log"
    start_worker localhost:18085
    ./bin/pubsub-worker seed
    finish_worker
    # The worker closed its stream. Stop the recorder so it flushes the capture.
    kill -TERM "$recorder"
    wait "$recorder"
    if ! grep -rq '/google.pubsub.v1.Subscriber/StreamingPull' "$recording"; then
      echo "No StreamingPull call was captured. See $run_dir/record.log." >&2
      exit 1
    fi
    printf 'Recording: %s\n' "$recording"
    ;;
  mock)
    test -d "$recording"
    "$proxymock" mock --in "$recording" --out "$run_dir/mocked" \
      --map 18085=localhost:8085 --pubsub-passes 2 --pubsub-gap-multiple 0.5 >"$run_dir/mock.log" 2>&1 &
    pids+=("$!")
    wait_for_port 18085 "$!" "$run_dir/mock.log"
    ./bin/pubsub-worker -addr localhost:18085 -count 6 -nack-first consume
    ;;
  republish)
    test -d "$recording"
    start_broker
    start_worker localhost:8085
    PUBSUB_EMULATOR_HOST=localhost:8085 "$proxymock" replay --in "$recording" \
      --tests-filter '(location CONTAINS "google.pubsub.v1.Subscriber")' \
      --test-config pubsub/republish.json --out "$run_dir/replayed" \
      --fail-if 'requests.total!=3' --fail-if 'requests.failed!=0'
    finish_worker
    ;;
  *)
    echo "usage: $0 record|mock|republish" >&2
    exit 2
    ;;
esac
