#!/usr/bin/env bash
# Proves: doctor exits 0 against this repo (committed lab recording and its
# staged blueprint reported, proxymock found), doctor exits 1 against an
# empty root with the missing recording named, every route dispatches --help
# to the correct sibling script (that script's usage text answers), and a
# bogus route and a bare invocation both exit 2 with usage. Hermetic: no
# cloud, no live downstream, no app build, no servers.
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
ql="$script_dir/quality-loop.sh"

need_cmd proxymock
need_cmd lsof
[[ -x "$ql" ]] || die "quality-loop script is not executable: $ql"
[[ -d "$repo_root/lab/proxymock/recording" ]] || die "missing committed recording: $repo_root/lab/proxymock/recording"

tmp="${TMPDIR:-/tmp}/quality-loop-proof.$$"
mkdir -p "$tmp"
cleanup() {
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  fi
}
trap cleanup EXIT

echo "== 1. doctor against the repo: healthy, recording and blueprint reported"
out="$tmp/doctor-repo.out"
rc=0
bash "$ql" doctor --root "$repo_root" >"$out" 2>&1 || rc=$?
[[ $rc -eq 0 ]] || { cat "$out" >&2; die "doctor against the repo exited $rc, want 0"; }
grep -q "lab/proxymock/recording" "$out" || { cat "$out" >&2; die "doctor did not report the committed recording"; }
grep -q "mocklab-smart-replace.json" "$out" || { cat "$out" >&2; die "doctor did not report the staged blueprint"; }
grep -q "^ok   proxymock:" "$out" || { cat "$out" >&2; die "doctor did not report the proxymock CLI"; }
grep -q "^healthy:" "$out" || { cat "$out" >&2; die "doctor did not print the healthy line"; }
echo "ok: doctor healthy against the repo"

echo "== 2. doctor against an empty root: exit 1, missing recording named"
mkdir -p "$tmp/empty"
out="$tmp/doctor-empty.out"
rc=0
bash "$ql" doctor --root "$tmp/empty" >"$out" 2>&1 || rc=$?
[[ $rc -eq 1 ]] || { cat "$out" >&2; die "doctor against an empty root exited $rc, want 1"; }
grep -q "^MISSING:" "$out" || { cat "$out" >&2; die "doctor did not print a MISSING list"; }
grep -q "no RRPair recording dirs" "$out" || { cat "$out" >&2; die "doctor did not name the missing recording"; }
echo "ok: doctor exits 1 and names the missing recording"

echo "== 3. dispatch smoke: every route reaches its sibling script"
routes="
regression:proxymock-regression-test.sh
verify-fix:proxymock-verify-fix.sh
perf:proxymock-perf-container.sh
chaos:proxymock-chaos-mock.sh
contract:proxymock-contract-test.sh
compare:proxymock-compare-results.sh
summarize:proxymock-summarize-recording.sh
tune:tune-proxymock-replay.sh
load:proxymock-load-test.sh
"
for pair in $routes; do
  route="${pair%%:*}"
  expect="${pair#*:}"
  out="$tmp/route-$route.out"
  rc=0
  bash "$ql" "$route" --help >"$out" 2>&1 || rc=$?
  [[ $rc -eq 0 ]] || { cat "$out" >&2; die "route $route --help exited $rc, want 0"; }
  grep -q "$expect" "$out" || { cat "$out" >&2; die "route $route did not reach $expect (usage text missing)"; }
  echo "ok: $route -> $expect"
done

echo "== 4. bogus route and bare invocation: usage error, exit 2"
out="$tmp/bogus.out"
rc=0
bash "$ql" not-a-route >"$out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] || { cat "$out" >&2; die "bogus route exited $rc, want 2"; }
grep -q "unknown route: not-a-route" "$out" || { cat "$out" >&2; die "bogus route did not name the unknown route"; }
grep -q "^Usage:" "$out" || { cat "$out" >&2; die "bogus route did not print usage"; }
rc=0
bash "$ql" >"$out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] || { cat "$out" >&2; die "bare invocation exited $rc, want 2"; }
grep -q "^Usage:" "$out" || { cat "$out" >&2; die "bare invocation did not print usage"; }
echo "ok: bogus route and bare invocation exit 2 with usage"

echo
echo "PASS: quality-loop proof complete"
