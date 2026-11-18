#!/usr/bin/env bash
# Send the requests the committed recording contains: four people whose
# session IDs change as their requests move through the storefront, plus a
# receipt link and a support lookup that carry no session at all.
set -euo pipefail

base=${1:-http://localhost:4143}
tenant="X-Tenant-Id: tenant-acme-001"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
# A shopper token from the identity provider. Its uid claim is what the
# storefront and proxymock key the shopper's own requests by.
user_jwt() {
  local header payload
  header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '{"iss":"idp.example","uid":"%s","sub":"%s"}' "$1" "$1" | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$(printf 'sig-%s' "$1" | b64url)"
}
show() { printf '%s %s\n' "$1" "$2"; }

# Every client first reads the tenant it belongs to.
show "$(curl -s -o /dev/null -w '%{http_code}' "$base/api/config")" "GET /api/config"

checkout() {
  local uid=$1 amount=$2 out
  out=$(curl -s -H "Authorization: Bearer $(user_jwt "$uid")" -H "$tenant" -H 'Content-Type: application/json' \
    --data "{\"amount_cents\":$amount}" "$base/api/checkout")
  sed -n 's/.*"paymentId":"\([^"]*\)".*/\1/p' <<<"$out"
}

# Alice checks out, her browser polls the payment, and later she opens the
# receipt link from her email.
alice_payment=$(checkout u-alice-1001 13857)
show "201" "POST /api/checkout (u-alice-1001 -> $alice_payment)"
show "$(curl -s -o /dev/null -w '%{http_code}' -H "$tenant" "$base/api/payments/$alice_payment?jsessionid=js-alice-77aa21")" "GET /api/payments/$alice_payment (browser)"
show "$(curl -s -o /dev/null -w '%{http_code}' "$base/api/receipts/$alice_payment")" "GET /api/receipts/$alice_payment (email link)"

# Bob does the same, from his own browser.
bob_payment=$(checkout u-bob-2002 4950)
show "201" "POST /api/checkout (u-bob-2002 -> $bob_payment)"
show "$(curl -s -o /dev/null -w '%{http_code}' -H "$tenant" "$base/api/payments/$bob_payment?jsessionid=js-bob-5c31d0")" "GET /api/payments/$bob_payment (browser)"

# A support tool looks up both payments at once, with no session of its own.
show "$(curl -s -o /dev/null -w '%{http_code}' -H "$tenant" -H 'Content-Type: application/json' \
  --data "{\"ids\":[\"$alice_payment\",\"$bob_payment\"]}" "$base/api/payments/lookup")" "POST /api/payments/lookup"

# Carol's browser is instrumented, so its trace context reaches the order service.
show "$(curl -s -o /dev/null -w '%{http_code}' -H "$tenant" \
  -H 'traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01' \
  "$base/api/orders?jsessionid=js-carol-4411")" "GET /api/orders (browser, traced)"

# Dave uses an internal tool with Basic auth.
show "$(curl -s -o /dev/null -w '%{http_code}' -H "$tenant" -u 'dave.ops:lab-password' "$base/api/profile")" "GET /api/profile (Basic)"
