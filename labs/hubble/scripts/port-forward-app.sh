#!/usr/bin/env bash
set -euo pipefail

context=${KUBE_CONTEXT:-hubble-lab}
pids=()

cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl --context "$context" -n netpath-demo port-forward service/catalog-api 8080:8080 &
pids+=("$!")
kubectl --context "$context" -n netpath-demo port-forward service/catalog-fixture 18090:8090 &
pids+=("$!")

wait
