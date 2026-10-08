#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != "baseline" && "$1" != "candidate" ) ]]; then
  echo "usage: $0 baseline|candidate" >&2
  exit 2
fi

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
context=${KUBE_CONTEXT:-opencost-lab}
variant=$1

kubectl --context "$context" apply -k "$root_dir/config/opencost/k8s/$variant"
kubectl --context "$context" -n catalog-fixture rollout status deployment/catalog-fixture --timeout=5m
kubectl --context "$context" -n catalog-api rollout status deployment/catalog-api --timeout=5m

observed_variant=$(kubectl --context "$context" -n catalog-api get deployment catalog-api \
  -o jsonpath='{.spec.template.metadata.labels.cost-variant}')
if [[ "$observed_variant" != "$variant" ]]; then
  echo "expected cost-variant '$variant', got '$observed_variant'" >&2
  exit 1
fi

echo "catalog-api is ready with the $variant allocation."
