#!/usr/bin/env bash
# Send the lab's request sequence to the shop API at $1 (default
# http://localhost:8080) and print one line per request: method, path, status
# and body. Every app prints the same lines against a freshly loaded database,
# which is what makes the outputs comparable across languages and runs.
set -euo pipefail
base=${1:-http://localhost:8080}

call() {
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -o /tmp/shop-drive.$$ -w '%{http_code}' -X "$method")
  if [[ -n $body ]]; then
    args+=(-H 'Content-Type: application/json' --data "$body")
  fi
  local status
  status=$(curl "${args[@]}" "$base$path")
  printf '%s %s %s %s\n' "$method" "$path" "$status" "$(cat /tmp/shop-drive.$$)"
  rm -f /tmp/shop-drive.$$
}

call GET /health
call GET '/products?category=bikes'
call GET '/products?category=parts'
call GET /products/1
call GET /products/4
call GET /products/99
call POST /orders '{"product_id":4,"quantity":2}'
call POST /orders '{"product_id":8,"quantity":1}'
call POST /orders '{"product_id":8,"quantity":1}'
call POST /orders '{"product_id":99,"quantity":1}'
call POST /orders '{"product_id":1,"quantity":1}'
call GET /orders/1
call GET /orders/3
call GET /orders/42
call GET /products/8
call GET '/reports/top-products?limit=2'
call GET /products/1
