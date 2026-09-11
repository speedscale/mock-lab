#!/usr/bin/env bash
set -euo pipefail
# Exports the Hubble flows for the saved interval as machine-readable JSON.
# Hubble has no MCP server, so the lab hands the agent a file instead.

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
window_file=${WINDOW_FILE:?set WINDOW_FILE to a window.json written by capture or probe}
out_file=${FLOWS_FILE:-$(dirname "$window_file")/flows.json}
hubble=${HUBBLE:-$root_dir/bin/hubble}
server=${HUBBLE_SERVER:-127.0.0.1:4245}
limit=${FLOW_LIMIT:-2000}

command -v "$hubble" >/dev/null 2>&1 || [[ -x "$hubble" ]] || {
  echo "hubble CLI not found at $hubble; run 'make hubble-cli' or set HUBBLE" >&2
  exit 1
}

query_start=$(jq -r .query_start "$window_file")
query_end=$(jq -r .query_end "$window_file")

"$hubble" observe \
  --server "$server" \
  --namespace netpath-demo \
  --since "$query_start" \
  --until "$query_end" \
  --last "$limit" \
  -o jsonpb >"$out_file"

flow_count=$(wc -l <"$out_file" | tr -d ' ')
dropped=$(jq -rs '[.[] | select(.flow.verdict == "DROPPED")] | length' "$out_file")

echo "Wrote $out_file: $flow_count flows in $query_start..$query_end, $dropped dropped"
