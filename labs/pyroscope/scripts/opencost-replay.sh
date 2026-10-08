#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 || ( "$1" != "functional" && "$1" != "load" ) || ( "$2" != "baseline" && "$2" != "candidate" ) ]]; then
  echo "usage: $0 functional|load baseline|candidate" >&2
  exit 2
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mode=$1
variant=$2
proxymock_bin=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
results_root=${RESULTS_DIR:-$root_dir/proxymock/results/opencost}
target_url=${OPENCOST_TARGET_URL:-http://127.0.0.1:18080}
result_dir="$results_root/$variant/$mode"

command -v "$proxymock_bin" >/dev/null || {
  echo "proxymock is required" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}
[[ -d "$recording_dir" ]] || {
  echo "recording directory '$recording_dir' does not exist; complete the Pyroscope guide's recording step first" >&2
  exit 1
}
ready=false
for _ in {1..30}; do
  if curl --fail --silent --max-time 1 "$target_url/healthz" --output /dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != "true" ]]; then
  echo "catalog API did not become healthy at $target_url" >&2
  exit 1
fi
rm -rf "$result_dir"
mkdir -p "$result_dir"

if [[ "$mode" == "functional" ]]; then
  "$proxymock_bin" replay \
    --in "$recording_dir" \
    --out "$result_dir" \
    --test-against "$target_url" \
    --rewrite-host \
    --times 3 \
    --fail-if 'requests.failed>0' \
    --fail-if 'requests.result-match-pct<100' \
    --output json >"$result_dir/summary.json"
  jq . "$result_dir/summary.json" >/dev/null
  echo "functional evidence: $result_dir"
  exit 0
fi

window_file="$result_dir/window.json"
summary_file="$result_dir/summary.json"
temporary_window="$window_file.tmp"
temporary_summary="$summary_file.tmp"
rm -f "$window_file" "$summary_file" "$temporary_window" "$temporary_summary"

warmup_seconds=${OPENCOST_WARMUP_SECONDS:-120}
load_duration=${OPENCOST_LOAD_DURATION:-3m}
load_vus=${OPENCOST_LOAD_VUS:-2}
latency_p95_ms=${OPENCOST_LATENCY_P95_MS:-250}

echo "warming the deployment for ${warmup_seconds}s so Prometheus has complete samples"
sleep "$warmup_seconds"

second_in_minute=$((10#$(date -u +%S)))
if ((second_in_minute != 0)); then
  alignment_wait=$((60 - second_in_minute))
  echo "waiting ${alignment_wait}s for a completed UTC minute boundary"
  sleep "$alignment_wait"
fi

start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if "$proxymock_bin" replay \
  --in "$recording_dir" \
  --out "$result_dir" \
  --test-against "$target_url" \
  --rewrite-host \
  --load-test \
  --vus "$load_vus" \
  --for "$load_duration" \
  --fail-if 'requests.failed>0' \
  --fail-if "latency.p95>$latency_p95_ms" \
  --output json >"$temporary_summary"; then
  end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq . "$temporary_summary" >/dev/null
  jq -n \
    --arg start "$start" \
    --arg end "$end" \
    --arg variant "$variant" \
    --argjson vus "$load_vus" \
    --arg latency_p95_slo_ms "$latency_p95_ms" \
    '{start:$start,end:$end,variant:$variant,vus:$vus,latency_p95_slo_ms:($latency_p95_slo_ms|tonumber)}' \
    >"$temporary_window"
  mv "$temporary_summary" "$summary_file"
  mv "$temporary_window" "$window_file"
  echo "load evidence: $result_dir"
else
  replay_status=$?
  echo "load replay failed; no completed window was published" >&2
  exit "$replay_status"
fi
