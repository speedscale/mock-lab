#!/usr/bin/env bash
set -euo pipefail

context=${KUBE_CONTEXT:-hubble-lab}
pids=()

cleanup() {
  for pid in "${pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# hubble CLI talks to relay on 4245; Hubble UI is a browser view of the same data.
kubectl --context "$context" -n kube-system port-forward service/hubble-relay 4245:80 &
pids+=("$!")
kubectl --context "$context" -n kube-system port-forward service/hubble-ui 12000:80 &
pids+=("$!")

wait
