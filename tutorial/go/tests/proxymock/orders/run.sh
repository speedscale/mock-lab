#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
PM="${PROXYMOCK:-proxymock}"
FIXTURE=tests/proxymock/orders
SPEC=../contract/openapi.yaml
PORT_BASE="${PORT_BASE:-18080}"
if [[ ! "$PORT_BASE" =~ ^[0-9]{4,5}$ ]] || (( 10#$PORT_BASE < 1024 || 10#$PORT_BASE > 65530 )); then
  echo 'PORT_BASE must be an integer from 1024 to 65530' >&2
  exit 1
fi
PORT_BASE=$((10#$PORT_BASE))
APP_PORT=$PORT_BASE
DB_PORT=$((PORT_BASE + 1))
CATALOG_PORT=$((PORT_BASE + 2))
PROXY_PORT=$((PORT_BASE + 3))
HEALTH_PORT=$((PORT_BASE + 4))
mkdir -p proxymock/results
OUT=$(mktemp -d proxymock/results/scenarios-XXXXXXXX)
OUT="$PWD/$OUT"
TARGET="http://127.0.0.1:$APP_PORT"
mock_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$mock_pid" ]]; then
    kill -INT "$mock_pid" 2>/dev/null || :
    wait "$mock_pid" 2>/dev/null || :
  fi
  if (( status != 0 )); then
    echo "Scenario recipe failed (exit $status). Native diagnostics:" >&2
    for log in "$OUT"/*.log "$OUT"/*contract.txt "$OUT"/*score.json; do
      [[ -f "$log" ]] || continue
      printf '\n%s\n' "$log" >&2
      tail -n 40 "$log" >&2
    done
  fi
  rm -rf "$OUT/orders" "$OUT/inputs"
  if [[ "${KEEP_RESULTS:-0}" == 1 ]]; then
    printf 'Native results retained: %s\n' "$OUT"
  else
    rm -rf "$OUT"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -R "$FIXTURE" "$OUT/inputs"
FIXTURE="$OUT/inputs"
go build -o "$OUT/orders" .

start_mock() {
  "$PM" mock --in "$FIXTURE/recording" --no-passthrough --mock-timing none \
    --map "$DB_PORT=postgres://127.0.0.1:63410,$CATALOG_PORT=http://127.0.0.1:63412" \
    --proxy-out-port "$PROXY_PORT" --health-port "$HEALTH_PORT" \
    --app-health-endpoint "$TARGET/healthz" --out "$OUT/$1" --out-format json "${@:2}" \
    -- env PORT="$APP_PORT" \
    DATABASE_URL="postgres://tutorial:tutorial@127.0.0.1:$DB_PORT/tutorial?sslmode=disable" \
    DEMO_API_URL="http://127.0.0.1:$CATALOG_PORT" APP_VERSION="${APP_VERSION:-v1}" "$OUT/orders" \
    > "$OUT/$1.log" 2>&1 &
  mock_pid=$!
  curl -fsS --max-time 1 --retry 10 --retry-max-time 10 --retry-connrefused --retry-delay 1 "$TARGET/healthz" > /dev/null
}
score_phase() {
  "$PM" replay score "$OUT/$1" --mock-run "$OUT/$2" -o json > "$OUT/$1-score.json"
  jq -e '.matchRate.total > 0 and .matchRate.noMatch == 0 and .matchRate.passthrough == 0
    and .goals.failed == 0 and .accuracy.pairs > 0 and .accuracy.mismatches == 0' "$OUT/$1-score.json" > /dev/null
}
wait_catalog() {
  local wanted=$1 deadline=$2 code remaining
  while (( SECONDS < deadline )); do
    kill -0 "$mock_pid" 2>/dev/null || { echo 'Mock exited during catalog polling' >&2; return 1; }
    remaining=$((deadline - SECONDS))
    (( remaining > 2 )) && remaining=2
    code=$(curl -sS --max-time "$remaining" -o /dev/null -w '%{http_code}' "$TARGET/catalog" 2>> "$OUT/catalog-poll.log") || code=000
    [[ "$code" == "$wanted" ]] && (( SECONDS < deadline )) && return 0
    sleep 0.2
  done
  echo "Catalog did not return $wanted before its deadline" >&2
  return 1
}
start_mock healthy-mock
"$PM" coverage --spec "$SPEC" --in "$FIXTURE/original" --json > "$OUT/original-coverage.json"
"$PM" coverage --spec "$SPEC" --in "$FIXTURE/recording" --json > "$OUT/generated-coverage.json"
"$PM" replay --in "$FIXTURE/recording" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/regression" --out-format json \
  --timeout 30s > "$OUT/regression.log" 2>&1
score_phase regression healthy-mock
"$PM" validate --spec "$SPEC" --in "$OUT/regression" > "$OUT/contract.txt"
"$PM" coverage --spec "$SPEC" --in "$OUT/regression" --json > "$OUT/exercised-coverage.json"
"$PM" replay --in "$FIXTURE/reads" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --fail-if 'latency.p95>250' \
  --fail-if 'requests.per-second<1' --fail-if 'requests.failed>0' \
  --vus 8 --for 2s --out "$OUT/load" --out-format json --timeout 30s > "$OUT/load.log" 2>&1
score_phase load healthy-mock
if ! kill -INT "$mock_pid" 2>/dev/null; then
  echo 'Healthy mock exited before requested shutdown' >&2
  wait "$mock_pid" || :
  exit 1
fi
wait "$mock_pid"
mock_pid=""

# The delayed window allows bounded startup; probes confirm the actual outage.
start_mock chaos-mock --chaos '(location REGEX "^/v1/projects"): status=503,percent=100,start-after=15s,duration=6s'
wait_catalog 502 "$((SECONDS + 20))"
"$PM" replay --in "$FIXTURE/chaos" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/chaos" --out-format json \
  --timeout 5s > "$OUT/chaos.log" 2>&1
# Recovery is bounded from the completed outage replay, including its assertions.
recovery_started=$SECONDS
recovery_deadline=$((recovery_started + 10))
wait_catalog 200 "$recovery_deadline"
remaining=$((recovery_deadline - SECONDS))
(( remaining > 0 )) || { echo 'Recovery deadline expired before assertions' >&2; exit 1; }
"$PM" replay --in "$FIXTURE/recovery" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/recovery" --out-format json \
  --timeout "${remaining}s" > "$OUT/recovery.log" 2>&1
(( SECONDS <= recovery_deadline )) || { echo 'Recovery assertions exceeded the 10-second deadline' >&2; exit 1; }
printf 'Recovery assertions passed in %ss (deadline: 10s after outage replay)\n' "$((SECONDS - recovery_started))" | tee "$OUT/recovery-timing.log"
score_phase chaos chaos-mock
score_phase recovery chaos-mock
"$PM" validate --spec "$SPEC" --in "$OUT/chaos" > "$OUT/chaos-contract.txt"
"$PM" validate --spec "$SPEC" --in "$OUT/recovery" > "$OUT/recovery-contract.txt"
# The native marker includes the applied rule, effect and as-sent status.
find "$OUT/chaos-mock" -name '*Z.json' -exec cat {} + | jq -es \
  '[.[] | select(.direction == "OUT") | .tags["X-Speedscale-Chaos"] // ""
    | select(contains("rule=chaos-1") and contains("effect=status code") and contains("status=503"))]
    | length > 0' > /dev/null
printf 'All native checks passed.\n'
