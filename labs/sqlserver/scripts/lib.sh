# Shared helpers for the lab scripts. Source it after setting root_dir.
proxymock=${PROXYMOCK:-proxymock}
log_dir=$root_dir/.run
mkdir -p "$log_dir"
pids=()

cleanup() {
  # stop in reverse order, so the app stops before the recorder or mock it talks through
  # a background job in a script starts with SIGINT ignored, so an app that keeps the default handling only stops
  # on TERM; proxymock catches INT and flushes what it recorded
  for (( i=${#pids[@]}-1; i>=0; i-- )); do
    local pid=${pids[$i]}
    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  pids=()
}
trap cleanup EXIT INT TERM

wait_for_port() {
  local port=$1 pid=$2 log=$3
  for _ in $(seq 1 120); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      cat "$log" >&2
      exit 1
    fi
    sleep 0.25
  done
  echo "nothing is listening on port $port; see $log" >&2
  exit 1
}

check_lang() {
  case ${1:-} in
    go|java|node|python) ;;
    *) echo "set APP to go, java, node or python" >&2; exit 2 ;;
  esac
}

reset_db() {
  docker compose -f "$root_dir/docker-compose.yaml" run --rm setup >"$log_dir/setup.log" 2>&1 || {
    cat "$log_dir/setup.log" >&2
    echo "could not load db/schema.sql; is SQL Server up (make up)?" >&2
    exit 1
  }
}
