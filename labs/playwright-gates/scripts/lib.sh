# Shared helpers for the lab's scripts: start servers in the background, wait
# for their ports, and stop them on exit.
pids=()

stop_all() {
  if [[ ${#pids[@]} -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
  pids=()
}
trap stop_all EXIT

wait_for_port() {
  for _ in $(seq 1 60); do
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
    sleep 0.25
  done
  echo "nothing listening on port $1" >&2
  return 1
}

# background <log> <command...>
background() {
  local log=$1; shift
  "$@" >>"$log" 2>&1 &
  pids+=($!)
}
