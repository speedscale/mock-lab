#!/usr/bin/env bash
set -euo pipefail

context=${KUBE_CONTEXT:-obi-lab}
pids=()

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

kubectl --context "$context" -n observability port-forward service/grafana 3002:3000 &
pids+=("$!")
kubectl --context "$context" -n observability port-forward service/tempo 3202:3200 &
pids+=("$!")
kubectl --context "$context" -n observability port-forward service/prometheus 19090:9090 &
pids+=("$!")

wait
