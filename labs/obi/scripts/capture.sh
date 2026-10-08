#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
context=${KUBE_CONTEXT:-obi-lab}
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
utc_now=${UTC_NOW:-$root_dir/bin/utc-now}
log_file=${CAPTURE_LOG:-$root_dir/proxymock/capture.log}
recorder_pid=

cleanup() {
  if [[ -n "$recorder_pid" ]]; then
    kill -INT "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$recording_dir"
mkdir -p "$recording_dir" "$(dirname "$log_file")"

"$proxymock" record --out "$recording_dir" -- \
  "$root_dir/scripts/port-forward-app.sh" \
  >"$log_file" 2>&1 &
recorder_pid=$!

for _ in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1:8080/ >/dev/null 2>&1 && \
     curl --fail --silent http://127.0.0.1:18090/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$recorder_pid" 2>/dev/null; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:8080/ >/dev/null
curl --fail --silent http://127.0.0.1:18090/healthz >/dev/null

capture_start=$("$utc_now")
query_start=${capture_start%%.*}Z
sleep 3
curl --fail --silent http://127.0.0.1:4143/api/stats >"$recording_dir/catalog-response.json"
sleep 4
capture_end=$("$utc_now")
sleep 1
query_end=$("$utc_now")
query_end=${query_end%%.*}Z

kill -INT "$recorder_pid"
wait "$recorder_pid"
recorder_pid=

printf '{\n  "capture_start": "%s",\n  "capture_end": "%s",\n  "query_start": "%s",\n  "query_end": "%s"\n}\n' \
  "$capture_start" "$capture_end" "$query_start" "$query_end" >"$recording_dir/window.json"

rrpair_count=$(find "$recording_dir" -type f -name '*.md' | wc -l | tr -d ' ')
if [[ "$rrpair_count" -lt 2 ]]; then
  echo "expected inbound and outbound RRPairs, found $rrpair_count; inspect $log_file" >&2
  exit 1
fi

echo "Captured $rrpair_count RRPairs and wrote $recording_dir/window.json"
