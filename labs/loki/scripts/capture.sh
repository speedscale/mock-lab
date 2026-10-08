#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
log_file=${CAPTURE_LOG:-$root_dir/proxymock/capture.log}
pricing_pid=
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
  if [[ -n "$pricing_pid" ]]; then
    kill "$pricing_pid" 2>/dev/null || true
    wait "$pricing_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$recording_dir"
mkdir -p "$recording_dir" "$(dirname "$log_file")"

"$root_dir/bin/pricing" >>"$log_file" 2>&1 &
pricing_pid=$!

for _ in $(seq 1 15); do
  if curl --fail --silent http://127.0.0.1:8090/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$pricing_pid" 2>/dev/null; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:8090/healthz >/dev/null

"$proxymock" record --out "$recording_dir" -- "$root_dir/bin/app" \
  >>"$log_file" 2>&1 &
recorder_pid=$!

for _ in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$recorder_pid" 2>/dev/null; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:8080/healthz >/dev/null

sleep 1

# One ordinary shopping session. Seven of the eight SKUs settle immediately;
# SSC-7300 happens to be inside a repricing window while the traffic is
# captured, which is the only reason the rare path is in the recording at all.
requests=(
  "SSC-4110 3"
  "SSC-4111 1"
  "SSC-5200 12"
  "SSC-7300 2"
  "SSC-5201 4"
  "SSC-6100 1"
  "SSC-6101 7"
  "SSC-8200 25"
)

mkdir -p "$recording_dir/responses"
for entry in "${requests[@]}"; do
  read -r sku qty <<<"$entry"
  curl --fail --silent "http://127.0.0.1:4143/api/quote?sku=$sku&qty=$qty" \
    >"$recording_dir/responses/$sku.json"
done
sleep 2

kill -INT "$recorder_pid"
wait "$recorder_pid" || true
recorder_pid=

kill "$pricing_pid"
wait "$pricing_pid" 2>/dev/null || true
pricing_pid=

inbound_count=$(grep -rlE '^GET .*/api/quote' "$recording_dir" --include='*.md' | wc -l | tr -d ' ')
outbound_count=$(grep -rlE '^GET .*/v1/price/' "$recording_dir" --include='*.md' | wc -l | tr -d ' ')
if [[ "$inbound_count" -lt 8 || "$outbound_count" -lt 8 ]]; then
  echo "expected 8 inbound quotes and at least 8 outbound price lookups, found $inbound_count and $outbound_count; inspect $log_file" >&2
  exit 1
fi

echo "Captured $inbound_count inbound quotes and $outbound_count outbound price lookups under $recording_dir"
