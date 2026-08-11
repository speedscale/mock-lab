#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile=${MINIKUBE_PROFILE:-opencost-lab}
context=${KUBE_CONTEXT:-opencost-lab}

for command_name in docker minikube kubectl helm; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

docker info >/dev/null

if ! minikube status -p "$profile" >/dev/null 2>&1; then
  minikube start \
    -p "$profile" \
    --driver=docker \
    --kubernetes-version=v1.34.0 \
    --cpus=4 \
    --memory=6144
fi

if ! kubectl config get-contexts "$context" >/dev/null 2>&1; then
  echo "expected Kubernetes context '$context' was not created" >&2
  exit 1
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add opencost https://opencost.github.io/opencost-helm-chart --force-update
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  --kube-context "$context" \
  --namespace prometheus-system \
  --create-namespace \
  --version 29.23.1 \
  --values "$root_dir/config/opencost/prometheus-values.yaml" \
  --wait \
  --timeout 10m

helm upgrade --install opencost opencost/opencost \
  --kube-context "$context" \
  --namespace opencost \
  --create-namespace \
  --version 2.5.29 \
  --values "$root_dir/config/opencost/opencost-values.yaml" \
  --wait \
  --timeout 10m

docker build \
  -t mock-lab-catalog:local \
  -f "$root_dir/Dockerfile.opencost" \
  "$root_dir"
minikube -p "$profile" image load mock-lab-catalog:local

kubectl --context "$context" apply -k "$root_dir/config/opencost/k8s/baseline"
kubectl --context "$context" -n catalog-fixture rollout restart deployment/catalog-fixture
kubectl --context "$context" -n catalog-api rollout restart deployment/catalog-api
kubectl --context "$context" -n catalog-fixture rollout status deployment/catalog-fixture --timeout=5m
kubectl --context "$context" -n catalog-api rollout status deployment/catalog-api --timeout=5m
kubectl --context "$context" -n opencost wait --for=condition=Ready pod -l app.kubernetes.io/name=opencost --timeout=5m

echo "OpenCost lab is ready in context '$context' with the baseline allocation."
