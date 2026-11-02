#!/usr/bin/env bash
# Deploys the shop from app/ and points api.localtest.me at shop-api inside the cluster.
set -euo pipefail

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
context=${KUBE_CONTEXT:-browser-journeys}
namespace=browser-journeys
kc() { kubectl --context "$context" "$@"; }

kc create namespace "$namespace" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$namespace" create configmap shop-spa --from-file="$root_dir/app/site/index.html" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$namespace" create configmap shop-api --from-file="$root_dir/app/api/server.js" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n "$namespace" apply -f "$root_dir/config/k8s/shop.yaml" >/dev/null
kc -n "$namespace" rollout restart deployment/shop-spa deployment/shop-api >/dev/null
kc -n "$namespace" rollout status deployment/shop-spa --timeout=5m
kc -n "$namespace" rollout status deployment/shop-api --timeout=5m

# On your machine api.localtest.me is 127.0.0.1. In the cluster the frontend's API
# has to be somewhere real for --no-mocks, so rewrite the name to the Service.
# This is cluster-wide DNS, which is fine in a cluster that exists only for this lab.
rule="rewrite name api.localtest.me shop-api.$namespace.svc.cluster.local"
corefile=$(kc -n kube-system get configmap coredns -o 'jsonpath={.data.Corefile}')
if ! grep -qF "$rule" <<<"$corefile"; then
  patched=$(awk -v rule="$rule" '{ print } /^[[:space:]]*ready[[:space:]]*$/ && !done { print "    " rule; done = 1 }' <<<"$corefile")
  kc -n kube-system create configmap coredns --from-literal=Corefile="$patched" --dry-run=client -o yaml \
    | kc apply -f - >/dev/null 2>&1
  kc -n kube-system rollout restart deployment/coredns >/dev/null
  kc -n kube-system rollout status deployment/coredns --timeout=2m
fi
