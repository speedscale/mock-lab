#!/usr/bin/env bash
# Records a journey, then drops what Chromium sends on its own account, such as
# its update and sign-in checks, so the recording holds only the shop's traffic.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
proxymock=${PROXYMOCK:-proxymock}
out=${RECORD_TO:-proxymock/my-recording}
frontend=${FRONTEND:-http://localhost:3000}

"$proxymock" record --browser "$frontend" --out "$out"

find "$out" -mindepth 1 -maxdepth 1 -type d \
  ! -name api.localtest.me ! -name 'localhost*' ! -name journeys ! -name '.*' \
  -exec rm -rf {} +
rm -f "$out/proxymock.log"

echo
echo "kept in $out:"
find "$out" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -exec basename {} \;
