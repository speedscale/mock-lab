#!/usr/bin/env bash
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root_dir/scripts/lib.sh"
cd "$root_dir"

paused=false
finish() {
  if [[ $paused == true ]]; then
    docker compose unpause oracle || true
  fi
  cleanup
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

port=${PORT:-8080}
DB_HOST=127.0.0.1 DB_PORT=${ORACLE_HOST_PORT:-15210} PORT=$port \
  ./scripts/app.sh java >"$log_dir/outage-java.log" 2>&1 &
pids+=($!)
wait_for_port "$port" "$!" "$log_dir/outage-java.log"

url=http://127.0.0.1:$port/products/1
baseline=$(curl -fsS --max-time 8 "$url")
printf 'Oracle available: HTTP 200 %s\n' "$baseline"

paused=true
docker compose pause oracle
during=$(curl -sS --max-time 8 --write-out '\n%{http_code}' "$url")
if [[ "$during" != $'{"error":"database unavailable"}\n503' ]]; then
  printf 'Expected the JDBC timeout to return HTTP 503, got %s\n' "$during" >&2
  exit 1
fi
printf 'Oracle paused: HTTP 503 {"error":"database unavailable"}\n'

docker compose unpause oracle
paused=false
recovered=$(curl -fsS --max-time 8 "$url")
if [[ "$recovered" != "$baseline" ]]; then
  printf 'Expected the original product after recovery, got %s\n' "$recovered" >&2
  exit 1
fi
printf 'Oracle resumed: HTTP 200 %s\n' "$recovered"
