#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
context=${KUBE_CONTEXT:-obi-lab}
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
results_dir=${RESULTS_DIR:-$root_dir/proxymock/results/baseline}
utc_now=${UTC_NOW:-$root_dir/bin/utc-now}
mode=${1:-functional}

case "$mode" in
  functional)
    replay_args=(--times 3 --out "$results_dir/functional")
    fail_args=(--fail-if 'requests.failed!=0' --fail-if 'requests.result-match-pct!=100')
    result_root="$results_dir/functional"
    ;;
  load)
    replay_args=(--load-test --vus 2 --times 50 --no-out)
    fail_args=(--fail-if 'requests.failed!=0')
    result_root="$results_dir/load"
    ;;
  *)
    echo "usage: $0 functional|load" >&2
    exit 2
    ;;
esac

if [[ "$mode" == load ]]; then
  jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0 and .metrics["requests.result-match-pct"] == 100)' \
    "$results_dir/functional/summary.json" >/dev/null || {
      echo "functional replay must pass before load replay" >&2
      exit 1
    }
fi

rm -rf "$result_root"
mkdir -p "$result_root"

mock_log="$results_dir/mock-$mode.log"
"$proxymock" mock --in "$recording_dir" --no-passthrough --no-out --health-port 4141 -- \
  "$root_dir/scripts/port-forward-app.sh" \
  >"$mock_log" 2>&1 &
mock_pid=$!
cleanup() {
  kill -INT "$mock_pid" 2>/dev/null || true
  wait "$mock_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  if curl --fail --silent http://127.0.0.1:4141/ >/dev/null 2>&1 && \
     curl --fail --silent http://127.0.0.1:8080/ >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$mock_pid" 2>/dev/null; then
    cat "$mock_log" >&2
    exit 1
  fi
  sleep 1
done
curl --fail --silent http://127.0.0.1:4141/ >/dev/null

temporary_summary="$results_dir/.${mode}-summary.json.tmp"
temporary_window="$results_dir/.${mode}-window.json.tmp"
capture_start=$("$utc_now")
query_start=${capture_start%%.*}Z
sleep 3
if "$proxymock" replay --in "$recording_dir" --test-against http://127.0.0.1:8080 \
  "${replay_args[@]}" --output json "${fail_args[@]}" >"$temporary_summary"; then
  sleep 4
  capture_end=$("$utc_now")
  sleep 1
  query_end=$("$utc_now")
  query_end=${query_end%%.*}Z
  printf '{\n  "capture_start": "%s",\n  "capture_end": "%s",\n  "query_start": "%s",\n  "query_end": "%s"\n}\n' \
    "$capture_start" "$capture_end" "$query_start" "$query_end" >"$temporary_window"
  mv "$temporary_summary" "$result_root/summary.json"
  mv "$temporary_window" "$result_root/window.json"
else
  status=$?
  if [[ -s "$temporary_summary" ]]; then
    mv "$temporary_summary" "$result_root/failed-summary.json"
  else
    rm -f "$temporary_summary"
  fi
  rm -f "$temporary_window"
  exit "$status"
fi

echo "Wrote $result_root/summary.json and $result_root/window.json"
