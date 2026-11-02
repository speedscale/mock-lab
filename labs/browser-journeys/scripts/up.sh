#!/usr/bin/env bash
# A disposable minikube profile running the released Speedscale operator and the
# shop. Safe to run again. Set MINIKUBE_START_ARGS to pick a driver or resources.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
profile=${MINIKUBE_PROFILE:-browser-journeys}
context=${KUBE_CONTEXT:-browser-journeys}
start_args=${MINIKUBE_START_ARGS:---cpus=4 --memory=6144}

for command_name in minikube kubectl helm; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

if [[ -z "${SPEEDSCALE_API_KEY:-}" ]]; then
  echo "set SPEEDSCALE_API_KEY: the operator will not start without one (see the README)" >&2
  exit 1
fi

# minikube start makes the new profile your default kubectl context. Every command
# in this lab names its context, so put your default back afterwards.
previous_context=$(kubectl config current-context 2>/dev/null || true)
restore_context() {
  if [[ -n "$previous_context" && "$previous_context" != "$context" ]]; then
    kubectl config use-context "$previous_context" >/dev/null
  fi
}
trap restore_context EXIT

status=$(minikube status -p "$profile" --format='{{.Host}}:{{.Kubelet}}:{{.APIServer}}' 2>/dev/null || true)
if [[ "$status" != "Running:Running:Running" ]]; then
  # shellcheck disable=SC2086 # the args are meant to split into flags
  minikube start -p "$profile" --kubernetes-version=v1.34.0 $start_args
fi

kubectl --context "$context" get --raw=/readyz --request-timeout=10s >/dev/null

helm repo add speedscale https://speedscale.github.io/operator-helm/ --force-update >/dev/null
helm repo update speedscale >/dev/null

# Released images only: the chart's own defaults, with no image overrides.
# The key goes through stdin so it stays out of the process list.
version_args=()
if [[ -n "${SPEEDSCALE_CHART_VERSION:-}" ]]; then
  version_args=(--version "$SPEEDSCALE_CHART_VERSION")
fi
printf 'apiKey: "%s"\n' "$SPEEDSCALE_API_KEY" | helm upgrade --install speedscale-operator speedscale/speedscale-operator \
  --kube-context "$context" \
  --namespace speedscale \
  --create-namespace \
  "${version_args[@]+"${version_args[@]}"}" \
  --values - \
  --set-string appUrl="${SPEEDSCALE_APP_URL:-app.speedscale.com}" \
  --set-string clusterName="${SPEEDSCALE_CLUSTER_NAME:-browser-journeys-lab}" \
  --set-string deployDemo= \
  --wait \
  --timeout 10m >/dev/null

kubectl --context "$context" -n speedscale rollout status deployment/speedscale-forwarder --timeout=5m

KUBE_CONTEXT="$context" "$root_dir/scripts/deploy.sh"

echo "lab is ready in kubectl context '$context'; your default context is unchanged"
