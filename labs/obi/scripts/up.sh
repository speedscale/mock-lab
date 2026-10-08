#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$(cd "$root_dir/.." && pwd)
profile=${MINIKUBE_PROFILE:-obi-lab}
context=${KUBE_CONTEXT:-obi-lab}

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
  minikube start \
    -p "$profile" \
    --driver=docker \
    --delete-on-failure \
    --kubernetes-version=v1.34.0 \
    --cpus=4 \
    --memory=7168
fi

kubectl --context "$context" get --raw=/readyz --request-timeout=5s >/dev/null

docker build -t mock-lab-obi:local -f "$root_dir/Dockerfile" "$repo_dir"
minikube -p "$profile" image load mock-lab-obi:local

kubectl --context "$context" apply -f "$root_dir/config/k8s/observability.yaml"

helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update
helm upgrade --install obi open-telemetry/opentelemetry-ebpf-instrumentation \
  --kube-context "$context" \
  --namespace obi \
  --create-namespace \
  --version 0.11.0 \
  --values "$root_dir/config/obi-values.yaml" \
  --wait \
  --timeout 10m

kubectl --context "$context" apply -f "$root_dir/config/k8s/app.yaml"
kubectl --context "$context" -n observability rollout restart deployment/tempo deployment/prometheus deployment/grafana
kubectl --context "$context" -n opaque-demo rollout restart deployment/catalog-fixture deployment/catalog-api
kubectl --context "$context" -n observability rollout status deployment/tempo --timeout=5m
kubectl --context "$context" -n observability rollout status deployment/prometheus --timeout=5m
kubectl --context "$context" -n observability rollout status deployment/grafana --timeout=5m
kubectl --context "$context" -n opaque-demo rollout status deployment/catalog-fixture --timeout=5m
kubectl --context "$context" -n opaque-demo rollout status deployment/catalog-api --timeout=5m
kubectl --context "$context" -n obi rollout status daemonset/obi --timeout=5m

minikube -p "$profile" ssh -- test -r /sys/kernel/btf/vmlinux
obi_logs=$(kubectl --context "$context" -n obi logs daemonset/obi --tail=200)
grep -q 'instrument' <<<"$obi_logs"

echo "OBI lab is ready in Kubernetes context '$context'."
