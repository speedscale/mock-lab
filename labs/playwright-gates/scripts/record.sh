#!/usr/bin/env bash
# Records the frontend's API calls without a person at the keyboard: runs the
# journeys once with plain Playwright through proxymock record's outbound proxy,
# then keeps only the app's traffic. Needs the site and the API running.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
proxymock=${PROXYMOCK:-proxymock}
out=${RECORD_TO:-proxymock/my-recording}
frontend=${FRONTEND:-http://localhost:3000}
work=$(mktemp -d)
trap 'stop_all; rm -rf "$work"' EXIT

cat >"$work/record.config.mjs" <<CONFIG
export default {
  testDir: '$PWD/journeys',
  testIgnore: '**/perf/**',
  outputDir: '$work/results',
  workers: 1,
  use: { baseURL: '$frontend', proxy: { server: 'http://localhost:4140' }, ignoreHTTPSErrors: true },
};
CONFIG

rm -rf "$out"
background "$work/record.log" "$proxymock" record --out "$out"
wait_for_port 4140
# The port opens before the proxy forwards. Warm it up with a request to the
# frontend, whose directory is dropped below, so the first journey's API call
# is not the one that waits.
for _ in $(seq 1 60); do
  curl -sf -o /dev/null -m 5 -x http://localhost:4140 "$frontend/" && break
  sleep 0.5
done
npx playwright test -c "$work/record.config.mjs" --reporter=line
stop_all

find "$out" -mindepth 1 -maxdepth 1 -type d ! -name api.localtest.me ! -name '.*' -exec rm -rf {} +
rm -f "$out/proxymock.log"
echo
echo "recorded in $out:"
grep -h -m1 -E '^(GET|POST|PUT|PATCH|DELETE|OPTIONS) ' "$out"/api.localtest.me/*.md | sed 's/ HTTP.*//' | sort | uniq -c
