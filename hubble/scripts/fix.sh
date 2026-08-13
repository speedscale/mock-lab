#!/usr/bin/env bash
set -euo pipefail
context=${KUBE_CONTEXT:-hubble-lab}
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
kubectl --context "$context" apply -f "$root_dir/config/k8s/policy-fixed.yaml"
kubectl --context "$context" -n netpath-demo wait --for=condition=Valid \
  ciliumnetworkpolicy/catalog-api-egress --timeout=60s >/dev/null 2>&1 || true
sleep 3
echo "Applied the corrected egress policy. The application image is still unchanged."
