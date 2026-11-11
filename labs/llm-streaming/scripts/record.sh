#!/usr/bin/env bash
# Record the chat client's streamed requests through proxymock's inbound proxy.
# The model server must already be running (make server).
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${RECORDING_DIR:-proxymock/recording}
format=${FORMAT:-openai}
requests=${REQUESTS:-8}
usage=${USAGE:-true}
app_port=${APP_PORT:-8000}
log_file=$root_dir/proxymock.log
recorder_pid=

cd "$root_dir"

cleanup() {
  if [[ -n "$recorder_pid" ]]; then
    kill -INT "$recorder_pid" 2>/dev/null || true
    wait "$recorder_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

curl --fail --silent "http://127.0.0.1:$app_port/healthz" >/dev/null || {
  echo "The model server is not answering on port $app_port. Start it with 'make server' in another terminal." >&2
  exit 1
}

rm -rf "$recording_dir"
"$proxymock" record --app-port "$app_port" --out "$recording_dir" >>"$log_file" 2>&1 &
recorder_pid=$!

# Wait for the inbound proxy port without sending a request through it, so the
# recording holds only the client's chat requests.
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 4143 2>/dev/null; then
    break
  fi
  if ! kill -0 "$recorder_pid" 2>/dev/null; then
    cat "$log_file" >&2
    exit 1
  fi
  sleep 0.5
done

./bin/chat-client -url http://127.0.0.1:4143 -format "$format" -n "$requests" -usage="$usage"

cleanup
recorder_pid=
echo "Recorded $(find "$recording_dir" -name '*.md' | wc -l | tr -d ' ') requests in $recording_dir"
