#!/usr/bin/env bash
# Send the twelve requests the committed recording contains.
set -euo pipefail

base=${1:-http://localhost:4143}

get() { curl --silent --show-error --output /dev/null --write-out "%{http_code} GET $1\n" "$base$1"; }
post() { curl --silent --show-error --output /dev/null --write-out "%{http_code} POST $1\n" -H 'Content-Type: application/json' --data "$2" "$base$1"; }

get /api/products/SKU-1001
get /api/products/SKU-4004
get /api/products/SKU-9999

post /api/quote '{"region":"CA","items":[{"sku":"SKU-1001","qty":2},{"sku":"SKU-3003","qty":3}]}'
post /api/quote '{"region":"GA","items":[{"sku":"SKU-1001","qty":2},{"sku":"SKU-3003","qty":3}]}'
post /api/quote '{"region":"TX","items":[{"sku":"SKU-1001","qty":3}]}'
post /api/quote '{"region":"OR","items":[{"sku":"SKU-2002","qty":1},{"sku":"SKU-1001","qty":1}]}'

post /api/checkout '{"region":"GA","card_token":"tok_visa","items":[{"sku":"SKU-1001","qty":2},{"sku":"SKU-3003","qty":3}]}'
post /api/checkout '{"region":"TX","card_token":"tok_visa","items":[{"sku":"SKU-2002","qty":1},{"sku":"SKU-1001","qty":1}]}'
post /api/checkout '{"region":"GA","card_token":"tok_amex","items":[{"sku":"SKU-2002","qty":1}]}'
post /api/checkout '{"region":"NJ","card_token":"tok_declined","items":[{"sku":"SKU-1001","qty":3}]}'
post /api/checkout '{"region":"TX","card_token":"tok_outage","items":[{"sku":"SKU-1001","qty":2},{"sku":"SKU-3003","qty":3}]}'
