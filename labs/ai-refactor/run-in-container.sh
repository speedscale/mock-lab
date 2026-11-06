#!/usr/bin/env bash
set -euo pipefail
pm=(proxymock --config /run/proxymock.yaml --app-url https://dev.speedscale.com)
results=/work/proxymock/results
mkdir -p "$results"
"${pm[@]}" version > "$results/version.txt"
find proxymock/recording proxymock/blueprints proxymock/applications proxymock/testconfigs -type f -print0 | sort -z | xargs -0 sha256sum > "$results/inputs.before.sha256"
mock_pid=
cleanup() {
  if [[ -n "$mock_pid" ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
    mock_pid=
  fi
}
trap cleanup EXIT
for variant in original broken fixed; do
  run="$results/$variant"
  mkdir -p "$run"
  if [[ "$variant" != original ]]; then
    (cd "/opt/demo/source/$variant" && go test -trimpath -v ./...) > "$run/unit-tests.log" 2>&1
  fi
  "${pm[@]}" mock --in proxymock/recording --no-passthrough \
    --out "$run/mocked" --timeout 3m -- "/opt/demo/bin/$variant" > "$run/mock.log" 2>&1 &
  mock_pid=$!
  ready=false
  for attempt in {1..60}; do
    kill -0 "$mock_pid" 2>/dev/null || break
    if curl -fsS http://localhost:8080/ > /dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [[ "$ready" != true ]]; then
    cat "$run/mock.log" >&2
    exit 1
  fi
  curl -fsS -D "$run/stats.headers" http://localhost:8080/api/stats > "$run/stats.json"
  gate=()
  if [[ "$variant" != original ]]; then
    gate=(--baseline "$results/original/replayed" --fail-on-new-mismatch)
  fi
  set +e
  "${pm[@]}" replay --in proxymock/recording \
    --test-against http://localhost:8080 --test-config regression \
    --require-blueprint 'mock-lab smart replace (token + order_id)' \
    --out "$run/replayed" --timeout 1m \
    --fail-if 'requests.total != 8' --fail-if 'requests.failed != 0' \
    "${gate[@]}" > "$run/replay.log" 2>&1
  code=$?
  set -e
  printf '%s\n' "$code" > "$run/exit-code.txt"
  cleanup
  expected=0
  [[ "$variant" != broken ]] || expected=3
  if [[ "$code" != "$expected" ]]; then
    cat "$run/replay.log" >&2
    echo "$variant: expected exit $expected, got $code" >&2
    exit 1
  fi
  echo "$variant: replay exit $code"
done
sha256sum -c "$results/inputs.before.sha256" > "$results/inputs.check.log"
python3 /opt/demo/verify.py "$results"
