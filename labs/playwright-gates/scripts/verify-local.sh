#!/usr/bin/env bash
# Runs every local step of the lab with its own servers and checks each result:
# exit code plus the lines that matter. Needs ports 3000, 4140, 4143 and 8082 free.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
proxymock=${PROXYMOCK:-proxymock}
logs=$(mktemp -d)
site_pid=""
trap 'stop_all; stop_site; echo "logs in $logs"' EXIT
failures=0

# check <name> <want exit> <expected line>... -- <command...>
check() {
  local name=$1 want=$2; shift 2
  local expect=()
  while [[ $1 != -- ]]; do expect+=("$1"); shift; done
  shift
  local got=0
  "$@" >"$logs/$name.log" 2>&1 || got=$?
  local ok=1
  [[ $got == "$want" ]] || ok=0
  for e in "${expect[@]}"; do grep -qF -- "$e" "$logs/$name.log" || { ok=0; echo "  missing: $e"; }; done
  if [[ $ok == 1 ]]; then echo "ok   $name (exit $got)"; else echo "FAIL $name (exit $got, want $want): $logs/$name.log"; failures=$((failures + 1)); fi
}

start_site() { node app/serve-site.js >>"$logs/site.log" 2>&1 & site_pid=$!; wait_for_port 3000; }
stop_site() { [[ -n $site_pid ]] && { kill "$site_pid" 2>/dev/null || true; wait "$site_pid" 2>/dev/null || true; }; site_pid=""; }

replay() { # <journeys> <test config>
  "$proxymock" replay --in proxymock/recording --test-against http://localhost:3000 \
    --browser-proxy http://localhost:4140 --browser-ignore-https-errors --browser "$1" \
    --browser-workers 3 --test-config "$2" --out "proxymock/results/verify-$(basename "$1")"
}

echo "== the team's suite, before the port"
check team-tests 0 "4 passed" -- npx playwright test -c tests --project chromium

echo "== record, headless"
start_site
background "$logs/api.log" node app/api/server.js
wait_for_port 8082
check record 0 "GET http://api.localtest.me:8082/v1/projects?q=prom" -- \
  env PROXYMOCK="$proxymock" RECORD_TO=proxymock/my-recording ./scripts/record.sh
stop_all

echo "== regression gate, API answered from the recording, API stopped"
background "$logs/mock.log" "$proxymock" mock --in proxymock/recording --no-passthrough
wait_for_port 4140
check regression-hermetic 0 "5 passed, 0 failed" "PASS browserJourneyPassPct >= 100" -- \
  replay journeys/read-only playwright-gates-regression
stop_site
SITE_BUG=search start_site
check regression-catches-bug 1 "4 passed, 1 failed" \
  "not in the recording: GET http://api.localtest.me:8082/v1/projects?query=prom" \
  "FAIL browserJourneyPassPct >= 100" -- replay journeys/read-only playwright-gates-regression
stop_site
stop_all

echo "== regression and performance gates against the real API"
start_site
background "$logs/api.log" node app/api/server.js
wait_for_port 8082
background "$logs/mock-real.log" "$proxymock" mock --in proxymock/recording --observe-real-apis
wait_for_port 4140
check regression-observed 0 "5 passed, 0 failed" -- replay journeys/read-only playwright-gates-regression
check writes 0 "1 passed, 0 failed" -- replay journeys/writes playwright-gates-regression
check perf 0 "15 passed, 0 failed" "PASS browserLcpP95 <= 250" -- replay journeys/perf playwright-gates-perf
stop_all
background "$logs/api-slow.log" env LATENCY_MS=800 node app/api/server.js
wait_for_port 8082
background "$logs/mock-real.log" "$proxymock" mock --in proxymock/recording --observe-real-apis
wait_for_port 4140
check perf-catches-slow-api 1 "15 passed, 0 failed" "FAIL browserLcpP95 <= 250" -- \
  replay journeys/perf playwright-gates-perf
stop_all
stop_site

echo "== performance Tier B: the API under load, from traffic the journeys generated"
check record-api 0 "GET http://api.localtest.me:4143/v1/projects" -- \
  env PROXYMOCK="$proxymock" RECORD_TO=proxymock/my-api-recording ./scripts/record-api.sh
background "$logs/api.log" node app/api/server.js
wait_for_port 8082
check load 0 'passed eval "latency.p95 > 50.00"' -- make --no-print-directory load PROXYMOCK="$proxymock" API_RECORDING=proxymock/my-api-recording
stop_all
background "$logs/api-slow.log" env LATENCY_MS=800 node app/api/server.js
wait_for_port 8082
check load-catches-slow-api 2 'failed eval "latency.p95 > 50.00"' -- make --no-print-directory load PROXYMOCK="$proxymock" API_RECORDING=proxymock/my-api-recording
stop_all

echo
if [[ $failures == 0 ]]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
