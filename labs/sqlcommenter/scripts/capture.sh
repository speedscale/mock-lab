#!/usr/bin/env bash
# Record one run of scripts/load.sh against a fresh database. proxymock sits in
# front of the app (inbound, port 4143) and in front of Postgres (a postgres
# listener on 15432 that forwards to the compose database on 54330), so the
# recording holds every request and every statement it ran.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-$root_dir/proxymock/recording}
log_file=${CAPTURE_LOG:-$root_dir/proxymock/capture.log}
pg_port=${PG_HOST_PORT:-54330}
recorder_pid=

case "$recording_dir" in
  /*) ;;
  *) recording_dir="$root_dir/$recording_dir" ;;
esac

cleanup() {
  if [[ -n "$recorder_pid" ]]; then
    kill -INT "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# A fresh database, so the recording starts from the same five products and one
# order every time.
(cd "$root_dir" && docker compose down -v >/dev/null 2>&1 && docker compose up -d --wait postgres >/dev/null 2>&1)

rm -rf "$recording_dir"
mkdir -p "$recording_dir" "$(dirname "$log_file")"
: >"$log_file"

PGPORT=15432 "$proxymock" record --out "$recording_dir" \
  --map "15432=postgres://localhost:$pg_port" --app-port 8080 \
  -- "$root_dir/bin/app" >>"$log_file" 2>&1 &
recorder_pid=$!

# Wait for the app to listen. Every endpoint runs SQL, so probe the port
# rather than an endpoint: a probe request would be recorded too.
for _ in $(seq 1 30); do
  if (exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null; then
    break
  fi
  if ! kill -0 "$recorder_pid" 2>/dev/null; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 1
done
(exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null
sleep 1

BASE_URL=http://127.0.0.1:4143 "$root_dir/scripts/load.sh"
sleep 2

kill -INT "$recorder_pid"
wait "$recorder_pid" || true
recorder_pid=

inbound=$(find "$recording_dir/localhost" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
database=$(find "$recording_dir/localhost-$pg_port" -type f 2>/dev/null | wc -l | tr -d ' ')
if [[ "$inbound" -lt 18 || "$database" -lt 20 ]]; then
  echo "expected 18 inbound requests and their database calls, found $inbound and $database; inspect $log_file" >&2
  exit 1
fi
echo "Captured $inbound inbound requests and $database database calls under $recording_dir"
