#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$(cd "$root_dir/.." && pwd)
profile=${MINIKUBE_PROFILE:-hubble-lab}
context=${KUBE_CONTEXT:-hubble-lab}
cilium_version=${CILIUM_VERSION:-1.19.6}

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
  # --cni=cilium is deliberately NOT used: it installs an unpinned Cilium.
  # Start with no CNI, then install the pinned chart below.
  minikube start \
    -p "$profile" \
    --driver=docker \
    --delete-on-failure \
    --kubernetes-version=v1.34.0 \
    --cni=false \
    --cpus=4 \
    --memory=7168
fi

kubectl --context "$context" get --raw=/readyz --request-timeout=5s >/dev/null

helm repo add cilium https://helm.cilium.io --force-update
helm upgrade --install cilium cilium/cilium \
  --kube-context "$context" \
  --namespace kube-system \
  --version "$cilium_version" \
  --values "$root_dir/config/cilium-values.yaml" \
  --set k8sServiceHost="$(minikube -p "$profile" ip)" \
  --set k8sServicePort=8443 \
  --wait \
  --timeout 10m

kubectl --context "$context" -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl --context "$context" -n kube-system rollout status deployment/hubble-relay --timeout=5m
kubectl --context "$context" -n kube-system rollout status deployment/coredns --timeout=5m

docker build -t mock-lab-hubble:local -f "$root_dir/Dockerfile" "$repo_dir"
minikube -p "$profile" image load mock-lab-hubble:local

kubectl --context "$context" apply -f "$root_dir/config/k8s/app.yaml"
kubectl --context "$context" -n netpath-demo rollout restart deployment/catalog-fixture deployment/catalog-api
kubectl --context "$context" -n netpath-demo rollout status deployment/catalog-fixture --timeout=5m
kubectl --context "$context" -n netpath-demo rollout status deployment/catalog-api --timeout=5m

# Start from the healthy state on every 'make up'.
kubectl --context "$context" -n netpath-demo delete ciliumnetworkpolicy catalog-api-egress --ignore-not-found

echo "Hubble lab is ready in Kubernetes context '$context' (Cilium $cilium_version)."
