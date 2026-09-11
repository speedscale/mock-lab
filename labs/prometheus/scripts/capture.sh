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
curl --fail --silent 'http://127.0.0.1:4143/api/quote?sku=SSC-4110&qty=3' \
  >"$recording_dir/quote-response.json"
sleep 2

kill -INT "$recorder_pid"
wait "$recorder_pid" || true
recorder_pid=

kill "$pricing_pid"
wait "$pricing_pid" 2>/dev/null || true
pricing_pid=

rrpair_count=$(find "$recording_dir" -type f -name '*.md' | wc -l | tr -d ' ')
if [[ "$rrpair_count" -lt 2 ]]; then
  echo "expected inbound and outbound RRPairs, found $rrpair_count; inspect $log_file" >&2
  exit 1
fi

echo "Captured $rrpair_count RRPairs under $recording_dir"
