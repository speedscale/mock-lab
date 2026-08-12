#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "baseline" && "$1" != "candidate" ) ]]; then
  echo "usage: $0 baseline|candidate" >&2
  exit 2
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
variant=$1
results_root=${RESULTS_DIR:-$root_dir/proxymock/results/opencost}
api_url=${OPENCOST_API_URL:-http://127.0.0.1:19003}
load_dir="$results_root/$variant/load"
window_file="$load_dir/window.json"
allocation_file="$load_dir/allocation.json"

[[ -s "$window_file" ]] || {
  echo "missing completed replay window: $window_file" >&2
  exit 1
}

window=$(jq -r '.start + "," + .end' "$window_file")
temporary_file="$allocation_file.tmp"
rm -f "$temporary_file"

for attempt in {1..12}; do
  curl --fail --silent --show-error --get "$api_url/allocation" \
    --data-urlencode "window=$window" \
    --data-urlencode 'aggregate=namespace' \
    --data-urlencode 'resolution=1m' >"$temporary_file"
  if jq -e '.data[0]["catalog-api"].totalCost | numbers' "$temporary_file" >/dev/null; then
    mv "$temporary_file" "$allocation_file"
    jq '.data[0]["catalog-api"] | {name,start,end,cpuCost,ramCost,totalCost}' "$allocation_file"
    exit 0
  fi
  echo "catalog-api allocation is not ingested yet (attempt $attempt/12); retrying the same window" >&2
  sleep 10
done

rm -f "$temporary_file"
echo "OpenCost did not return catalog-api allocation for exact window $window" >&2
exit 1
