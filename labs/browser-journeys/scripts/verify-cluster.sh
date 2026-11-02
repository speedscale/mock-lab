#!/usr/bin/env bash
# Runs the lab's cloud-free cluster steps and checks each result. Run make up first.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib-verify.sh
export PROXYMOCK KUBE_CONTEXT
restore() { make --no-print-directory restore-api >/dev/null 2>&1 || true; }
trap restore EXIT

restore
check cluster-mocks 0 "result: Passed" "PASS browserJourneyPassPct" -- make --no-print-directory cluster
check cluster-failing 2 "result: Missed Goals (success rate 33.3%)" \
  "browserJourneyFailed: shopper pages through the items" \
  "browserJourneyFailed: shopper sees a checkout button" \
  "screenshots and traces of failed journeys" -- make --no-print-directory cluster-failing
check cluster-real 0 "result: Passed" "go to the real APIs" -- make --no-print-directory cluster-real
make --no-print-directory change-api >/dev/null
check cluster-real-changed 2 "result: Missed Goals" \
  "browserJourneyFailed: shopper loads the item list" -- make --no-print-directory cluster-real

finish
