#!/usr/bin/env bash
# Tier B of the performance gate. The browser's captured calls are outbound, and a
# load replay sends only inbound requests, so record the API's own inbound
# traffic while the journeys drive the frontend. Needs nothing else running.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
proxymock=${PROXYMOCK:-proxymock}
out=${RECORD_TO:-proxymock/my-api-recording}
work=$(mktemp -d)
trap 'stop_all; rm -rf "$work"' EXIT

rm -rf "$out"
# proxymock starts the API and records what reaches it on its inbound port, 4143.
background "$work/record.log" "$proxymock" record --out "$out" --app-port 8082 -- node app/api/server.js
wait_for_port 8082
wait_for_port 4143
# The frontend sends its API calls through the recording port.
API_BASE=http://api.localtest.me:4143 background "$work/site.log" node app/serve-site.js
wait_for_port 3000

cat >"$work/drive.config.mjs" <<CONFIG
export default {
  testDir: '$PWD/journeys',
  testIgnore: ['**/writes/**'],
  outputDir: '$work/results',
  workers: 2,
  use: { baseURL: 'http://localhost:3000' },
};
CONFIG
npx playwright test -c "$work/drive.config.mjs" --reporter=line
stop_all
rm -f "$out/proxymock.log"

echo
echo "recorded in $out:"
find "$out" -name '*.md' -path '*/localhost/*' -exec grep -h -m1 -E '^(GET|POST|OPTIONS) ' {} + \
  | sed -E 's/ HTTP.*//; s/\?.*//' | sort | uniq -c
