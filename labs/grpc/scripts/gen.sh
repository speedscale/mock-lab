#!/usr/bin/env bash
# Regenerate the Go code in gen/ from proxymock/protos/, the same .proto that
# proxymock reads to name the recorded calls. Needs protoc, protoc-gen-go,
# protoc-gen-go-grpc, and a googleapis checkout for the google/api and
# google/type imports:
#
#   GOOGLEAPIS=/path/to/googleapis scripts/gen.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${GOOGLEAPIS:?set GOOGLEAPIS to a googleapis checkout}"
protoc -I proxymock/protos -I "$GOOGLEAPIS" \
  --go_out=. --go_opt=module=github.com/speedscale/mock-lab/grpc \
  --go-grpc_out=. --go-grpc_opt=module=github.com/speedscale/mock-lab/grpc \
  proxymock/protos/acme/orders/v1/orders.proto
