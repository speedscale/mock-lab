#!/usr/bin/env bash
set -euo pipefail
# Drives /api/stats against the live cluster and saves a machine-owned interval
# plus the observed application evidence. Used in the broken state, where the
# only thing the application can tell you is that something timed out.

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
context=${KUBE_CONTEXT:-hubble-lab}
out_dir=${OUT_DIR:-$root_dir/proxymock/failure}
utc_now=${UTC_NOW:-$root_dir/bin/utc-now}
count=${PROBE_COUNT:-3}
forward_pid=

cleanup() {
  if [[ -n "$forward_pid" ]]; then
    kill "$forward_pid" 2>/dev/null || true
    wait "$forward_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$out_dir"
mkdir -p "$out_dir"

kubectl --context "$context" -n netpath-demo port-forward service/catalog-api 8080:8080 \
  >"$out_dir/port-forward.log" 2>&1 &
forward_pid=$!

for _ in $(seq 1 60); do
  curl --fail --silent --max-time 2 http://127.0.0.1:8080/ >/dev/null 2>&1 && break
  sleep 1
done

capture_start=$("$utc_now")
query_start=${capture_start%%.*}Z
sleep 2

: >"$out_dir/observations.txt"
for i in $(seq 1 "$count"); do
  status=$(curl --silent --show-error --max-time 30 \
    --output "$out_dir/response-$i.json" \
    --write-out '%{http_code} %{time_total}' \
    http://127.0.0.1:8080/api/stats || echo "000 0")
  printf 'attempt %s http_status=%s duration_s=%s\n' "$i" ${status} >>"$out_dir/observations.txt"
  cat "$out_dir/response-$i.json" >>"$out_dir/observations.txt"
  printf '\n' >>"$out_dir/observations.txt"
done

sleep 3
capture_end=$("$utc_now")
sleep 1
query_end=$("$utc_now")
query_end=${query_end%%.*}Z

printf '{\n  "capture_start": "%s",\n  "capture_end": "%s",\n  "query_start": "%s",\n  "query_end": "%s"\n}\n' \
  "$capture_start" "$capture_end" "$query_start" "$query_end" >"$out_dir/window.json"

# Whatever the application itself managed to say about the failure.
kubectl --context "$context" -n netpath-demo logs deployment/catalog-api --tail=50 \
  >"$out_dir/catalog-api.log" 2>&1 || true

cat "$out_dir/observations.txt"
echo "Wrote $out_dir/window.json"
