#!/usr/bin/env bash
# Proves, hermetically (no app build, no network, no cloud): the committed
# recording's outbound pairs conform to the committed spec (exit 0); a seeded
# type violation is caught with exact JSON-path attribution (exit 2); a pair
# whose route is absent from the spec reports partial coverage (exit 3);
# mock-from-spec generates loadable RRPairs from the committed spec and warns
# about the enum-without-example self-conformance gap; and a missing --spec is
# a usage error (exit 4).
set -euo pipefail

# shared ql_* helpers; a copied skill needs skills/lib/common.sh too
if [[ ! -r "$(dirname "$0")/../../lib/common.sh" ]]; then
  echo "FAIL: missing $(dirname "$0")/../../lib/common.sh (copy skills/lib/common.sh alongside this skill)" >&2
  exit 1
fi
source "$(dirname "$0")/../../lib/common.sh"

die() { ql_fail "$@"; }
need_cmd() { ql_prove_need_cmd "$1"; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(cd "$skill_dir/../.." && pwd)"
contract_script="$script_dir/proxymock-contract-test.sh"

need_cmd python3
need_cmd proxymock
need_cmd curl
need_cmd lsof
[[ -x "$contract_script" ]] || die "contract-test script is not executable: $contract_script"

spec="$repo_root/lab/openapi.yaml"
recording="$repo_root/lab/proxymock/recording"
outbound="$recording/demo-api.trafficreplay.com"
[[ -f "$spec" ]] || die "missing committed spec: $spec"
[[ -d "$outbound" ]] || die "missing committed outbound recording: $outbound"

tmp="${TMPDIR:-/tmp}/proxymock-contract-proof.$$"
mock_pid=""
mock_port=""
cleanup() {
  if [[ -n "$mock_pid" ]]; then
    ql_stop_pid_and_port "$mock_pid" "$mock_port"
  elif [[ -n "$mock_port" ]]; then
    ql_sweep_port "$mock_port"
  fi
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp"

echo "case a: committed outbound pairs vs committed spec (expect exit 0)"
# The committed spec covers the downstream's read routes, which is exactly
# what the recorded demo-api pairs exercise; conformance here proves the
# spec and the recording still agree.
"$contract_script" conformance \
  --spec "$spec" --in "$outbound" \
  --work-dir "$tmp/a" >"$tmp/a.out" 2>&1 || {
    cat "$tmp/a.out" >&2
    die "case a: expected exit 0 on the committed recording"
  }
cat "$tmp/a.out"
grep -q '5 conformant, 0 violating, 0 without a spec route' "$tmp/a.out" \
  || die "case a: expected 5/5 conformant"
[[ -s "$tmp/a/summary.json" ]] || die "case a: no summary.json written"

echo
echo "case b: seeded type violation stars:\"many\" (expect exit 2, exact attribution)"
mkdir -p "$tmp/seeded"
cp "$outbound/2026-06-25_18-56-36.852193Z.md" "$tmp/seeded/"
python3 - "$tmp/seeded/2026-06-25_18-56-36.852193Z.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
seeded = text.replace('"stars": 110000', '"stars": "many"', 1)
if seeded == text:
    raise SystemExit("seed target '\"stars\": 110000' not found in the pair")
open(path, "w").write(seeded)
PY
rc=0
"$contract_script" conformance \
  --spec "$spec" --in "$tmp/seeded" \
  --work-dir "$tmp/b" >"$tmp/b.out" 2>&1 || rc=$?
cat "$tmp/b.out"
[[ "$rc" -eq 2 ]] || die "case b: expected exit 2, got $rc"
grep -qF "\$[0].stars: type mismatch, expected integer, got str ('many')" "$tmp/b.out" \
  || die "case b: exact violation string not found in output"

echo
echo "case c: pair whose route is not in the spec (expect exit 3, pair named)"
mkdir -p "$tmp/noroute"
cp "$recording/localhost/2026-06-25_18-56-36.620937Z.md" "$tmp/noroute/"
rc=0
"$contract_script" conformance \
  --spec "$spec" --in "$tmp/noroute" --paths '^/api/' \
  --work-dir "$tmp/c" >"$tmp/c.out" 2>&1 || rc=$?
cat "$tmp/c.out"
[[ "$rc" -eq 3 ]] || die "case c: expected exit 3, got $rc"
grep -q 'NO_ROUTE.*GET /api/projects' "$tmp/c.out" \
  || die "case c: NO_ROUTE pair not named in output"

echo
echo "case d: mock-from-spec generates, warns on enum gaps, and the mock loads"
rc=0
"$contract_script" mock-from-spec \
  --spec "$spec" --serve \
  --work-dir "$tmp/d" >"$tmp/d.out" 2>&1 || rc=$?
cat "$tmp/d.out"
# record pid/port for cleanup before asserting, so a late failure still sweeps
if [[ -s "$tmp/d/serve.json" ]]; then
  mock_pid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$tmp/d/serve.json")"
  mock_port="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["proxyOutPort"])' "$tmp/d/serve.json")"
fi
[[ "$rc" -eq 0 ]] || die "case d: expected exit 0, got $rc"
pair_count="$(find "$tmp/d/generated" -type f -name '*.md' | wc -l | tr -d ' ')"
[[ "$pair_count" -gt 0 ]] || die "case d: no RRPairs generated"
empty=0
while IFS= read -r f; do
  # body = second fenced block of the RESPONSE section; the 404 pair's empty
  # body is spec-correct, so only 200s must be non-empty
  body="$(python3 - "$f" <<'PY'
import re, sys
text = open(sys.argv[1]).read().split("### RESPONSE ###", 1)[1].split("### ", 1)[0]
blocks = re.findall(r"```\n(.*?)```", text, re.S)
print(blocks[1].strip() if len(blocks) > 1 else "")
PY
)"
  [[ -n "$body" ]] || empty=$((empty + 1))
done < <(find "$tmp/d/generated" -type f -name '*_200.md')
[[ "$empty" -eq 0 ]] || die "case d: $empty generated 200 pair(s) have empty bodies"
grep -q 'example_value' "$tmp/d.out" \
  || die "case d: enum-without-example warning did not fire"
grep -q 'mock is up' "$tmp/d.out" || die "case d: mock did not report loaded"
[[ -n "$mock_pid" ]] || die "case d: serve.json missing pid"
echo "generated $pair_count pair(s), all 200 bodies non-empty, enum warning fired, mock loaded"
ql_stop_pid_and_port "$mock_pid" "$mock_port"
mock_pid=""
mock_port=""

echo
echo "case e: missing --spec (expect exit 4)"
rc=0
"$contract_script" conformance --in "$outbound" --work-dir "$tmp/e" \
  >"$tmp/e.out" 2>&1 || rc=$?
[[ "$rc" -eq 4 ]] || die "case e: expected exit 4, got $rc"
grep -q -- '--spec is required' "$tmp/e.out" || die "case e: usage error not reported"

echo
echo "PASS: conformance clean on committed assets, seeded violation attributed,"
echo "PASS: partial coverage reported, spec-only mock generated and loaded, usage gated"
