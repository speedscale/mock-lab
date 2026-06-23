#!/usr/bin/env bash
# Run the whole demo locally with the production topology (app -> static CNCF origin).
# Picks free ports automatically so it never collides with anything already running.
# Override with ORIGIN_PORT / APP_PORT if you want fixed ports. Ctrl-C stops everything.
set -euo pipefail
cd "$(dirname "$0")"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
ORIGIN_PORT="${ORIGIN_PORT:-$(free_port)}"
APP_PORT="${APP_PORT:-$(free_port)}"

BIN_DIR="$(mktemp -d)"
_cleaned=0
cleanup() {
  [ "${_cleaned}" = 1 ] && return 0
  _cleaned=1
  echo
  echo "stopping..."
  kill "${ORIGIN_PID:-}" "${APP_PID:-}" 2>/dev/null || true
  rm -rf "${BIN_DIR}"
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

echo "Rendering static dataset -> ./static"
(cd server && go run . -export ../static) >/dev/null

echo "Building app"
(cd go && go build -o "${BIN_DIR}/app" .)

echo "Origin (CloudFront/S3 stand-in) : http://localhost:${ORIGIN_PORT}"
( cd static && exec python3 -m http.server "${ORIGIN_PORT}" ) >/tmp/proxymock-demo-origin.log 2>&1 &
ORIGIN_PID=$!

echo "Demo app                        : http://localhost:${APP_PORT}"
DOWNSTREAM_URL="http://localhost:${ORIGIN_PORT}" PORT="${APP_PORT}" "${BIN_DIR}/app" >/tmp/proxymock-demo-app.log 2>&1 &
APP_PID=$!

for _ in $(seq 1 40); do
  curl -sf "http://localhost:${APP_PORT}/" >/dev/null 2>&1 && break
  sleep 0.5
done

echo
echo "=== smoke test ==="
PORT="${APP_PORT}" ./tests/run_http_tests.sh

echo
echo "Ready. Try:"
echo "  curl http://localhost:${APP_PORT}/api/projects"
echo "  curl http://localhost:${APP_PORT}/api/projects/cilium"
echo "  curl http://localhost:${APP_PORT}/api/stats"
echo
echo "Logs: /tmp/proxymock-demo-app.log  /tmp/proxymock-demo-origin.log"
echo "Ctrl-C to stop."
wait
