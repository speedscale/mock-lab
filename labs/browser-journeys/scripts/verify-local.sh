#!/usr/bin/env bash
# Runs the lab's local steps with the committed recording and checks each result.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib-verify.sh
proxymock=${PROXYMOCK:-proxymock}
recording=proxymock/recording
frontend=http://localhost:3000
pids=()

stop_all() {
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
  pids=()
}
trap stop_all EXIT

wait_for_port() {
  for _ in $(seq 1 40); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.25
  done
  echo "nothing listening on port $1" >&2
  return 1
}

background() {
  "$@" >>"$log_dir/background.log" 2>&1 &
  pids+=($!)
}

replay() { # <journeys dir> <results dir>
  "$proxymock" replay --in "$recording" --browser "$1" --test-against "$frontend" \
    --browser-proxy http://localhost:4140 --browser-workers 2 --out "proxymock/results/$2"
}

node app/serve-site.js >"$log_dir/site.log" 2>&1 &
site_pid=$!
trap 'stop_all; kill "$site_pid" 2>/dev/null || true' EXIT
wait_for_port 3000

# Mocks on, with no API running at all.
background "$proxymock" mock --in "$recording" --no-passthrough
wait_for_port 4140
check local-mocks 0 "1 passed, 0 failed" -- replay journeys verify-mocks
check local-failing 1 "1 passed, 2 failed" \
  "not in the recording: GET http://api.localtest.me:8081/items?page=2" \
  "shopper sees a checkout button" -- replay journeys-failing verify-failing
stop_all

# Mocks off, against the real API, as recorded and then changed.
background node app/api/server.js
wait_for_port 8081
background "$proxymock" mock --in "$recording" --observe-real-apis
wait_for_port 4140
check local-real 0 "1 passed, 0 failed" -- replay journeys verify-real
stop_all

ITEM_FIELD=title background node app/api/server.js
wait_for_port 8081
background "$proxymock" mock --in "$recording" --observe-real-apis
wait_for_port 4140
check local-real-changed 1 "0 passed, 1 failed" \
  "answered differently from the recording: GET http://api.localtest.me:8081/items (Body JSON)" \
  -- replay journeys verify-real-changed

finish
