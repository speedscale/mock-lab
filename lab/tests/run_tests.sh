#!/usr/bin/env bash
# Drives the demo app's whole API in one pass — the 5 read endpoints, then the OAuth
# handshake + order flow (the two "moving IDs": access_token and order_id). proxymock
# records this, so you can view it in `proxymock web` and replay it.
#
# Run from the repo root:
#   ./lab/tests/run_tests.sh                # hit the app directly on :8080 (set PORT to change)
#   ./lab/tests/run_tests.sh --recording    # hit proxymock's inbound proxy on :4143
#   DELAY=0 ./lab/tests/run_tests.sh        # no pause between calls (CI); DELAY defaults to 1s
set -euo pipefail

PORT="${PORT:-8080}"
if [[ "${1:-}" == "--recording" ]]; then
  PORT=4143
  echo "Recording mode: driving proxymock's inbound proxy on :$PORT"
fi
BASE="http://localhost:${PORT}"
DELAY="${DELAY:-1}"
PROJECT="${PROJECT:-kubernetes}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

CODE=""
# req METHOD PATH [json-body] [bearer-token] -> sets $CODE, writes body to $TMP
req() {
  local method="$1" path="$2" data="${3:-}" auth="${4:-}"
  local args=(-s -o "$TMP" -w '%{http_code}' -X "$method" "${BASE}${path}")
  [[ -n "$auth" ]] && args+=(-H "Authorization: Bearer ${auth}")
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' -d "$data")
  CODE="$(curl "${args[@]}")"
}
expect() { [[ "$CODE" == "$1" ]] || { echo "  FAIL: expected HTTP $1, got $CODE"; cat "$TMP"; exit 1; }; }
field()  { grep -o "\"$1\": *\"[^\"]*\"" "$TMP" | sed "s/.*\"$1\": *\"//;s/\"$//" | head -1; }
step()   { echo; echo "▶ $*"; }

# --- read endpoints ---------------------------------------------------------
step "GET /  — service info"
req GET /; expect 200; head -c 160 "$TMP"; echo; sleep "$DELAY"

step "GET /api/projects  — all CNCF projects"
req GET /api/projects; expect 200
n="$(grep -o '"id"' "$TMP" | wc -l | tr -d ' ')"; echo "  → $n projects"
[[ "$n" == "24" ]] || { echo "  FAIL: expected 24 projects"; exit 1; }
sleep "$DELAY"

step "GET /api/projects/${PROJECT}  — one project"
req GET "/api/projects/${PROJECT}"; expect 200; head -c 200 "$TMP"; echo; sleep "$DELAY"

step "GET /api/categories  — categories with counts"
req GET /api/categories; expect 200; head -c 160 "$TMP"; echo; sleep "$DELAY"

step "GET /api/stats  — counts by maturity"
req GET /api/stats; expect 200; tr -d '\n ' < "$TMP"; echo; sleep "$DELAY"

# --- oauth handshake + order flow (the two moving IDs) ----------------------
step "POST /oauth/token  → access_token (moving ID #1, rides in the Authorization header)"
req POST /oauth/token; expect 200
tok="$(field access_token)"; [[ -n "$tok" ]] || { echo "  FAIL: no access_token"; exit 1; }
echo "  → ${tok:0:16}…"; sleep "$DELAY"

step "POST /api/orders  (Bearer, project=${PROJECT}) → order_id (moving ID #2, rides in the next path)"
req POST /api/orders "{\"project\":\"${PROJECT}\"}" "$tok"; expect 201
oid="$(field order_id)"; [[ -n "$oid" ]] || { echo "  FAIL: no order_id"; exit 1; }
echo "  → ${oid}"; sleep "$DELAY"

step "GET /api/orders/${oid}  (Bearer) — read the order back"
req GET "/api/orders/${oid}" "" "$tok"; expect 200; head -c 200 "$TMP"; echo

echo; echo "✅ All endpoints OK (5 read + oauth/token + create order + get order)."
