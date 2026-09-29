#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

mkdir -p .run/baseline/recording
cp -R proxymock/recording/. .run/baseline/recording/

STARTUP_QUERY='environment=lab' proxymock mock \
  --in .run/baseline/recording --no-passthrough --no-out \
  --log-to .run/baseline-proxymock.log -- ./bin/config-service \
  >.run/baseline-app.log 2>&1 || true

if ! grep -q 'startup dependency returned 404 Not Found' .run/baseline-app.log; then
  cat .run/baseline-app.log >&2
  cat .run/baseline-proxymock.log >&2
  echo 'Expected startup to fail without the blueprint' >&2
  exit 1
fi

STARTUP_QUERY='environment=lab' proxymock mock \
  --in proxymock/recording --no-passthrough --no-out \
  --log-to .run/fixed-proxymock.log -- ./bin/config-service \
  >.run/fixed-app.log 2>&1 &
mock_pid=$!
trap 'kill -INT "$mock_pid" 2>/dev/null || true; wait "$mock_pid" 2>/dev/null || true' EXIT

ready=0
for _ in $(seq 1 30); do
  if curl --noproxy '*' --fail --silent http://127.0.0.1:18080/healthz | grep -q '^ready$'; then
    ready=1
    break
  fi
  if ! kill -0 "$mock_pid" 2>/dev/null; then
    break
  fi
  sleep 1
done

if [[ "$ready" != 1 ]] || ! grep -q 'startup dependency matched:' .run/fixed-app.log; then
  cat .run/fixed-app.log >&2
  cat .run/fixed-proxymock.log >&2
  echo 'Expected startup to succeed with the blueprint' >&2
  exit 1
fi

echo 'Baseline: startup failed with 404'
echo 'Blueprint: startup completed with the backend offline'
