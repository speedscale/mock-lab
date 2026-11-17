#!/usr/bin/env bash
# Record one app: the requests the driver sends it, and every call it makes to
# Oracle, through proxymock.
#
#   drive.sh ──► :4143 proxymock ──► :8080 shop ──► :11521 proxymock ──► :15210 Oracle
#
# The database is reloaded first, so every recording starts from the same rows.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root_dir/scripts/lib.sh"
lang=${1:-}
check_lang "$lang"
recording_dir=proxymock/recording-$lang
cd "$root_dir"

reset_db
rm -rf "$recording_dir"
"$proxymock" record --app-port 8080 --out "$recording_dir" \
  --map 11521=oracle://127.0.0.1:15210 >"$log_dir/record-$lang.log" 2>&1 &
pids+=($!)
wait_for_port 4143 "$!" "$log_dir/record-$lang.log"
wait_for_port 11521 "$!" "$log_dir/record-$lang.log"

DB_PORT=11521 ./scripts/app.sh "$lang" >"$log_dir/app-$lang.log" 2>&1 &
pids+=($!)
wait_for_port 8080 "$!" "$log_dir/app-$lang.log"

./scripts/drive.sh http://localhost:4143 | tee "$log_dir/drive-$lang.txt"
cleanup

if ! diff -u expected.txt "$log_dir/drive-$lang.txt"; then
  echo "the $lang app answered differently from expected.txt while recording" >&2
  exit 1
fi
if [[ ! -d $recording_dir/localhost-15210 ]]; then
  echo "no Oracle calls were recorded; see $log_dir/record-$lang.log" >&2
  exit 1
fi
inbound=$(find "$recording_dir/localhost" -name '*.md' | wc -l | tr -d ' ')
database=$(find "$recording_dir/localhost-15210" -name '*.json' | wc -l | tr -d ' ')
echo "Recorded $inbound inbound requests and $database Oracle calls in $recording_dir"
