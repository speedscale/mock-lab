#!/usr/bin/env bash
# Drives the OAuth + order flow, exercising the two moving IDs:
#   access_token (from POST /oauth/token, into the Authorization header) and
#   order_id (from POST /api/orders, into the GET /api/orders/{id} path).
# proxymock records this so replay can re-run it; on replay both IDs are
# regenerated, so smart replace must chain them from the responses.
set -euo pipefail

PORT="${PORT:-8080}"
if [[ "${1:-}" == "--recording" ]]; then
  PORT=4143
  echo "Recording mode enabled, using port $PORT"
fi
BASE="http://localhost:${PORT}"
PROJECT="${PROJECT:-kubernetes}"

echo "POST ${BASE}/oauth/token"
tok=$(curl -s -X POST "${BASE}/oauth/token" \
  | grep -o '"access_token": *"[^"]*"' | sed 's/.*"access_token": *"//;s/"$//')
if [[ -z "$tok" ]]; then echo "FAIL: no access_token"; exit 1; fi
echo "  got token ${tok:0:12}..."

echo "POST ${BASE}/api/orders (project=${PROJECT})"
oid=$(curl -s -X POST "${BASE}/api/orders" \
  -H "Authorization: Bearer ${tok}" -H 'Content-Type: application/json' \
  -d "{\"project\":\"${PROJECT}\"}" \
  | grep -o '"order_id": *"[^"]*"' | sed 's/.*"order_id": *"//;s/"$//')
if [[ -z "$oid" ]]; then echo "FAIL: no order_id"; exit 1; fi
echo "  got order_id ${oid}"

echo "GET ${BASE}/api/orders/${oid}"
code=$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/orders/${oid}" \
  -H "Authorization: Bearer ${tok}")
if [[ "$code" != "200" ]]; then echo "FAIL: get order returned ${code}"; exit 1; fi
echo "  OK (${code})"

echo "Auth flow passed."
