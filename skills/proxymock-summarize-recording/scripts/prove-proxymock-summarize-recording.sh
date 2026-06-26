#!/usr/bin/env bash
# Proves: summarizing the committed recording enumerates the downstream host,
# both inbound and outbound endpoints, a status mix, and the report digest.
set -euo pipefail

die() {
  echo "FAIL: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$skill_dir/../.." && pwd)"
summarize_script="$script_dir/proxymock-summarize-recording.sh"

need_cmd proxymock
need_cmd python3
[[ -x "$summarize_script" ]] || die "summarize script is not executable: $summarize_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-summarize-proof.$$"
cleanup() {
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp"

out="$tmp/summary.md"
"$summarize_script" --in "$recording" --out "$out" --work-dir "$tmp" >"$tmp/run.out" 2>&1 \
  || { cat "$tmp/run.out" >&2; die "summarize exited nonzero"; }
cat "$tmp/run.out"

[[ -s "$out" ]] || die "summary markdown was not written"

python3 - "$out" <<'PY'
import re, sys
text = open(sys.argv[1]).read()

def need(cond, msg):
    if not cond:
        raise SystemExit(f"summary missing: {msg}")

need("demo-api.trafficreplay.com" in text, "downstream host demo-api.trafficreplay.com")
need(re.search(r"^##\s+Inbound endpoints", text, re.M), "Inbound endpoints section")
need(re.search(r"^##\s+Outbound endpoints", text, re.M), "Outbound endpoints section")
need("/v1/" in text, "an outbound /v1/* downstream endpoint")
need(re.search(r"\*\*Status mix:\*\*.*2xx", text), "a 2xx status mix line")
need(re.search(r"^##\s+Findings & recommendations", text, re.M), "report digest section")
need("Security" in text or "Performance" in text, "a report pillar in the digest")
print("PASS: summary enumerates host, inbound + outbound endpoints, status mix, and digest")
PY
