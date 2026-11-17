#!/usr/bin/env bash
# Reload db/schema.sql, so the database holds the rows every recording started
# from. With --wait it retries for up to a minute: on first start the image
# creates the shop user a few seconds after the database reports healthy.
set -euo pipefail
root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root_dir/scripts/lib.sh"

if [[ ${1:-} == --wait ]]; then
  for _ in $(seq 1 30); do
    if (reset_db) 2>/dev/null; then
      exit 0
    fi
    sleep 2
  done
fi
reset_db
