#!/usr/bin/env bash
set -euo pipefail

context=${KUBE_CONTEXT:-opencost-lab}
app_port=${OPENCOST_APP_PORT:-18080}
api_port=${OPENCOST_API_PORT:-19003}
mcp_port=${OPENCOST_MCP_PORT:-18081}

children=()
cleanup() {
  if ((${#children[@]})); then
    kill "${children[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

forward_forever() {
  local namespace=$1
  local health_url=$2
  local forward_pid=
  shift
  shift
  trap '[[ -z "$forward_pid" ]] || kill "$forward_pid" 2>/dev/null || true; exit 0' INT TERM
  while true; do
    kubectl --context "$context" -n "$namespace" port-forward "$@" >/dev/null 2>&1 &
    forward_pid=$!
    if [[ -n "$health_url" ]]; then
      local failures=0
      while kill -0 "$forward_pid" 2>/dev/null; do
        sleep 2
        if curl --fail --silent --max-time 1 "$health_url" --output /dev/null; then
          failures=0
        else
          failures=$((failures + 1))
          if ((failures >= 2)); then
            kill "$forward_pid" 2>/dev/null || true
            break
          fi
        fi
      done
    fi
    wait "$forward_pid" 2>/dev/null || true
    echo "port-forward for $namespace disconnected; reconnecting" >&2
    sleep 1
  done
}

forward_forever catalog-api "http://127.0.0.1:$app_port/healthz" service/catalog-api "$app_port:8080" &
children+=("$!")
forward_forever opencost "" service/opencost "$api_port:9003" "$mcp_port:8081" &
children+=("$!")

echo "catalog-api: http://127.0.0.1:$app_port"
echo "OpenCost API: http://127.0.0.1:$api_port"
echo "OpenCost MCP: http://127.0.0.1:$mcp_port/"

wait "${children[@]}"
