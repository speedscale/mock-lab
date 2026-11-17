#!/usr/bin/env bash
# Replay one recording's Oracle calls against the real database, with no app
# at all, and fail unless every statement returns what it returned when it was
# recorded. The database is reloaded first, so the replayed inserts get the
# same order ids as the recorded ones.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root_dir/scripts/lib.sh"
lang=${1:-}
check_lang "$lang"
cd "$root_dir"

# load-test mode does not score results, so it cannot fail on them
fail_if_match=(--fail-if 'requests.result-match-pct < 100')
if [[ " ${*:2} " == *" --load-test "* ]]; then
  fail_if_match=()
fi

reset_db
ORACLE_USER=shop ORACLE_PASSWORD="${APP_USER_PASSWORD:-LabShop2026}" "$proxymock" replay --in "proxymock/recording-$lang" \
  --tests-filter '(direction IS OUT) AND (tech IS Oracle)' \
  --test-against oracle://127.0.0.1:15210/FREEPDB1 \
  --fail-if 'requests.failed != 0' \
  ${fail_if_match[@]+"${fail_if_match[@]}"} "${@:2}"
