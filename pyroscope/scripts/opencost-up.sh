#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile=${MINIKUBE_PROFILE:-opencost-lab}
context=${KUBE_CONTEXT:-opencost-lab}

for command_name in docker minikube kubectl helm jq; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

docker info >/dev/null

profile_status=$(minikube status -p "$profile" \
  --format='{{.Host}}:{{.Kubelet}}:{{.APIServer}}:{{.Kubeconfig}}' \
  2>/dev/null || true)
if [[ "$profile_status" != "Running:Running:Running:Configured" ]]; then
  echo "starting minikube profile '$profile' (current state: ${profile_status:-missing or stale})"
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

if ! kubectl --context "$context" get --raw=/readyz --request-timeout=5s >/dev/null 2>&1; then
  echo "Kubernetes context '$context' is not ready after starting minikube profile '$profile'" >&2
  echo "To recreate only this isolated lab, run: minikube delete -p '$profile'" >&2
  exit 1
fi

reset_pending_helm_release() {
  local namespace=$1
  local release=$2
  local release_status

  release_status=$(helm --kube-context "$context" --namespace "$namespace" \
    status "$release" --output json 2>/dev/null | \
    jq -r '.info.status // empty' 2>/dev/null || true)
  case "$release_status" in
    pending-*)
      echo "removing interrupted Helm release '$release' ($release_status)"
      helm --kube-context "$context" --namespace "$namespace" \
        uninstall "$release" --wait --timeout 5m
      ;;
  esac
}

reset_pending_helm_release prometheus-system prometheus
reset_pending_helm_release opencost opencost

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
