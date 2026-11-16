#!/usr/bin/env bash
# Run one app against proxymock's SQL Server mock instead of the database, and
# check that it answers every request as it did against the database. SQL
# Server does not need to be running.
#
#   drive.sh ──► :8080 shop ──► :11433 proxymock mock (answers from recording-<lang>)
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root_dir/scripts/lib.sh"
lang=${1:-}
check_lang "$lang"
recording_dir=proxymock/recording-$lang
cd "$root_dir"

out_dir=$log_dir/mocked-$lang
rm -rf "$out_dir"
"$proxymock" mock --in "$recording_dir" --out "$out_dir" --no-passthrough \
  --map 11433=mssql://localhost:14330 >"$log_dir/mock-$lang.log" 2>&1 &
pids+=($!)
wait_for_port 11433 "$!" "$log_dir/mock-$lang.log"

DB_PORT=11433 ./scripts/app.sh "$lang" >"$log_dir/app-$lang.log" 2>&1 &
pids+=($!)
wait_for_port 8080 "$!" "$log_dir/app-$lang.log"

./scripts/drive.sh http://localhost:8080 >"$log_dir/drive-mock-$lang.txt"
cleanup

diff -u expected.txt "$log_dir/drive-mock-$lang.txt"
hits=$( (grep -rho '"match": *"HIT"' "$out_dir" || true) | wc -l | tr -d ' ')
others=$( (grep -rhoE '"match": *"[A-Z_]+"' "$out_dir" || true) | grep -vc HIT || true)
echo "The $lang app answered all $(wc -l < expected.txt | tr -d ' ') requests as in expected.txt with SQL Server mocked:"
echo "  $hits SQL Server calls answered from the recording, $others not"
if [[ $others != 0 ]]; then
  exit 1
fi
