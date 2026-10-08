#!/usr/bin/env bash
# Record one ordinary browsing session with the inventory service healthy.
#
# Nothing rare happens here, on purpose. The sibling Loki lab needed its rare
# response to be present in the traffic on the day it was captured; this lab
# needs no such luck, because the failure is injected later on demand.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
log_file=${CAPTURE_LOG:-$root_dir/proxymock/capture.log}
inventory_pid=
recorder_pid=

case "$recording_dir" in
  /*) ;;
  *) recording_dir="$root_dir/$recording_dir" ;;
esac

cleanup() {
  if [[ -n "$recorder_pid" ]]; then
    kill -INT "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
  fi
  if [[ -n "$inventory_pid" ]]; then
    kill "$inventory_pid" 2>/dev/null || true
    wait "$inventory_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$recording_dir"
mkdir -p "$recording_dir" "$(dirname "$log_file")"

"$root_dir/bin/inventory" >>"$log_file" 2>&1 &
inventory_pid=$!

for _ in $(seq 1 15); do
  curl --fail --silent http://127.0.0.1:8090/healthz >/dev/null 2>&1 && break
  if ! kill -0 "$inventory_pid" 2>/dev/null; then cat "$log_file" >&2; exit 1; fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:8090/healthz >/dev/null

"$proxymock" record --out "$recording_dir" -- "$root_dir/bin/app" >>"$log_file" 2>&1 &
recorder_pid=$!

for _ in $(seq 1 30); do
  curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null 2>&1 && break
  if ! kill -0 "$recorder_pid" 2>/dev/null; then cat "$log_file" >&2; exit 1; fi
  sleep 1
done
sleep 1

# Requests go through proxymock's inbound reverse proxy on 4143, not straight
# at the app on 8080, so both directions of each exchange land in the recording.
skus=(SSC-4110 SSC-4111 SSC-5200 SSC-5201 SSC-6100 SSC-7300)
mkdir -p "$recording_dir/responses"
for sku in "${skus[@]}"; do
  curl --fail --silent "http://127.0.0.1:4143/api/stock/$sku" \
    >"$recording_dir/responses/$sku.json"
done
sleep 2

kill -INT "$recorder_pid"; wait "$recorder_pid" || true; recorder_pid=
kill "$inventory_pid"; wait "$inventory_pid" 2>/dev/null || true; inventory_pid=

inbound=$(grep -rlE '^GET .*/api/stock/' "$recording_dir" --include='*.md' | wc -l | tr -d ' ')
outbound=$(grep -rlE '^GET .*/v1/inventory/' "$recording_dir" --include='*.md' | wc -l | tr -d ' ')
if [[ "$inbound" -lt 6 || "$outbound" -lt 6 ]]; then
  echo "expected 6 inbound stock lookups and 6 outbound inventory calls, found $inbound and $outbound; inspect $log_file" >&2
  exit 1
fi

echo "Captured $inbound inbound stock lookups and $outbound outbound inventory calls under $recording_dir"
