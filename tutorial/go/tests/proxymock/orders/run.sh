#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
PM="${PROXYMOCK:-proxymock}"
FIXTURE=tests/proxymock/orders
SPEC=../contract/openapi.yaml
PORT_BASE="${PORT_BASE:-18080}"
[[ "$PORT_BASE" =~ ^[0-9]+$ ]] && (( PORT_BASE >= 1024 && PORT_BASE <= 65530 ))
APP_PORT=$PORT_BASE
DB_PORT=$((PORT_BASE + 1))
CATALOG_PORT=$((PORT_BASE + 2))
PROXY_PORT=$((PORT_BASE + 3))
HEALTH_PORT=$((PORT_BASE + 4))
mkdir -p proxymock/results
OUT=$(mktemp -d proxymock/results/scenarios-XXXXXXXX)
OUT="$PWD/$OUT"
cp -R "$FIXTURE" "$OUT/inputs"
FIXTURE="$OUT/inputs"
TARGET="http://127.0.0.1:$APP_PORT"
mock_pid=""
trap 'if [[ -n "$mock_pid" ]]; then kill -INT "$mock_pid" 2>/dev/null || :; wait "$mock_pid" 2>/dev/null || :; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
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
  curl -fsS --retry 10 --retry-connrefused --retry-delay 1 "$TARGET/healthz" > /dev/null
}

start_mock healthy-mock
"$PM" coverage --spec "$SPEC" --in "$FIXTURE/original" --json > "$OUT/original-coverage.json"
"$PM" coverage --spec "$SPEC" --in "$FIXTURE/recording" --json > "$OUT/generated-coverage.json"
"$PM" replay --in "$FIXTURE/recording" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/regression" --out-format json \
  --timeout 30s > "$OUT/regression.log" 2>&1
"$PM" validate --spec "$SPEC" --in "$OUT/regression" > "$OUT/contract.txt"
"$PM" coverage --spec "$SPEC" --in "$OUT/regression" --json > "$OUT/exercised-coverage.json"
"$PM" replay --in "$FIXTURE/reads" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/budgets.json" --vus 8 --for 2s --out "$OUT/load" \
  --out-format json --timeout 30s > "$OUT/load.log" 2>&1
"$PM" replay score "$OUT/load" --mock-run "$OUT/healthy-mock" -o json > "$OUT/score.json"
jq -e '.matchRate.total > 0 and .matchRate.noMatch == 0 and .matchRate.passthrough == 0
  and .goals.failed == 0 and .accuracy.pairs > 0 and .accuracy.mismatches == 0' "$OUT/score.json" > /dev/null
kill -INT "$mock_pid"
wait "$mock_pid"
mock_pid=""

start_mock chaos-mock --chaos '(location REGEX "^/v1/projects"): status=503,percent=100,start-after=2s,duration=6s'
sleep 2
"$PM" replay --in "$FIXTURE/chaos" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/chaos" --out-format json \
  --timeout 10s > "$OUT/chaos.log" 2>&1
sleep 6
"$PM" replay --in "$FIXTURE/recovery" --test-against "$TARGET" --rewrite-host \
  --test-config "$FIXTURE/checks.json" --out "$OUT/recovery" --out-format json \
  --timeout 10s > "$OUT/recovery.log" 2>&1
"$PM" validate --spec "$SPEC" --in "$OUT/chaos" > "$OUT/chaos-contract.txt"
"$PM" validate --spec "$SPEC" --in "$OUT/recovery" > "$OUT/recovery-contract.txt"
"$PM" replay score "$OUT/recovery" --mock-run "$OUT/chaos-mock" -o json > "$OUT/recovery-score.json"
jq -e '.matchRate.total > 0 and .matchRate.noMatch == 0 and .matchRate.passthrough == 0
  and .goals.failed == 0 and .accuracy.pairs > 0 and .accuracy.mismatches == 0' "$OUT/recovery-score.json" > /dev/null
# The native marker includes the applied rule, effect and as-sent status.
find "$OUT/chaos-mock" -name '*Z.json' -exec cat {} + | jq -es \
  '[.[] | select(.direction == "OUT") | .tags["X-Speedscale-Chaos"] // ""
    | select(contains("rule=chaos-1") and contains("effect=status code") and contains("status=503"))]
    | length > 0' > /dev/null
printf 'All native checks passed. Results: %s\n' "$OUT"
