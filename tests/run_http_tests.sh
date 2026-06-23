#!/usr/bin/env bash
# Exercises the demo app's inbound API. proxymock records these requests so it can
# later replay them as tests. Pass --recording to hit proxymock's inbound port.
set -euo pipefail

PORT="${PORT:-8080}"
if [[ "${1:-}" == "--recording" ]]; then
  PORT=4143
  echo "Recording mode enabled, using port $PORT"
fi
BASE="http://localhost:${PORT}"

PATHS=(
  "/"
  "/api/projects"
  "/api/projects/kubernetes"
  "/api/categories"
  "/api/stats"
)

fail=0
for p in "${PATHS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}${p}")
  if [[ "$code" == "200" ]]; then
    echo "Testing ${BASE}${p}... OK (${code})"
  else
    echo "Testing ${BASE}${p}... FAIL (${code})"
    fail=1
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "Http tests passed."
else
  echo "Http tests failed."
  exit 1
fi
