#!/usr/bin/env bash
# Gate a model swap on answer quality, end to end. Replays the recorded
# assistant requests at a model that answers as recorded and at one that
# regressed, checks that the gate passes the first and fails the second, then
# compares the two runs. Starts both model servers itself.
set -uo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
proxymock=${PROXYMOCK:-proxymock}
recording_dir=${EVAL_RECORDING_DIR:-proxymock/eval-recording}
results_dir=${RESULTS_DIR:-proxymock/results}
baseline_port=${BASELINE_PORT:-8010}
candidate_port=${CANDIDATE_PORT:-8011}
# The candidate serves another model name and takes another key, as a new
# checkpoint on its own server would. The key is a lab value, not a secret.
candidate_model=checkpoint-b
export LAB_CANDIDATE_KEY=${LAB_CANDIDATE_KEY:-lab-candidate-key}
pids=()

cd "$root_dir"

cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

start_server() {
  local port=$1
  shift
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    echo "Port $port is in use. Set BASELINE_PORT or CANDIDATE_PORT to a free port." >&2
    exit 2
  fi
  env PORT="$port" "$@" ./bin/model-server >>"$root_dir/model-server.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 30); do
    curl --fail --silent "http://127.0.0.1:$port/healthz" >/dev/null && return
    sleep 0.2
  done
  echo "The model server did not start on port $port. See model-server.log." >&2
  exit 2
}

# gate replays the recording at one model with the two quality conditions and
# returns proxymock's exit code: 0 when both conditions hold, 1 when one fails.
gate() {
  local name=$1 port=$2
  shift 2
  rm -rf "$results_dir/eval-$name"
  "$proxymock" replay --in "$recording_dir" --test-against "http://localhost:$port" \
    --out "$results_dir/eval-$name" \
    --fail-if 'llm.tool-call-match-pct < 100' \
    --fail-if 'llm.failure-pct > 0' "$@"
}

start_server "$baseline_port"
start_server "$candidate_port" MODE=regressed FIRST_TOKEN_MS=360 \
  MODEL_NAME="$candidate_model" API_KEY="$LAB_CANDIDATE_KEY"

echo "== 1. The model that answers as recorded"
gate baseline "$baseline_port"
baseline_exit=$?
echo "proxymock exit code: $baseline_exit"

echo
echo "== 2. The regressed model"
gate candidate "$candidate_port" --llm-model "$candidate_model" --llm-api-key-env LAB_CANDIDATE_KEY
candidate_exit=$?
echo "proxymock exit code: $candidate_exit"

echo
echo "== 3. The regressed model's run against the other one"
"$proxymock" replay score "$results_dir/eval-candidate" --baseline "$results_dir/eval-baseline" \
  --html "$results_dir/eval-comparison.html"

# A failed gate means the answers got worse only when the regressed model
# answered. A replay that left no readable verdict, scored nothing, or was
# turned away by the model fails the gate too, and says nothing about answers.
verdict=$results_dir/eval-candidate/replay-verdict.json
if ! counts=$(jq -er '.summary.llm | "\(.scored) \(.noCompletion // 0)"' "$verdict" 2>/dev/null); then
  echo "The regressed model's replay left no readable verdict at $verdict." >&2
  exit 1
fi
read -r scored unanswered <<<"$counts"
if [[ ! $scored =~ ^[1-9][0-9]*$ ]]; then
  echo "The regressed model's replay scored no answers. See $verdict." >&2
  exit 1
fi
if [[ $unanswered -ne 0 ]]; then
  echo "The regressed model returned no answer to $unanswered request(s). See model-server.log." >&2
  exit 1
fi

echo
if [[ $baseline_exit -eq 0 && $candidate_exit -eq 1 ]]; then
  echo "The gate passed the model that answers as recorded and failed the regressed one."
  exit 0
fi
echo "Expected exit code 0 for the first replay and 1 for the second, got $baseline_exit and $candidate_exit." >&2
exit 1
