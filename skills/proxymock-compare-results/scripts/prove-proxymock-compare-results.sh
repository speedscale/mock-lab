#!/usr/bin/env bash
# Proves: the compare workflow writes report files and the Compare report
# detects a seeded regression (a HIGH finding present in current but not in the
# baseline) while reporting none when current == baseline.
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
compare_script="$script_dir/proxymock-compare-results.sh"

need_cmd proxymock
need_cmd python3
[[ -x "$compare_script" ]] || die "compare script is not executable: $compare_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-compare-proof.$$"
cleanup() {
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp"

current="$tmp/current"
baseline="$tmp/baseline"
cp -R "$recording" "$current"
cp -R "$recording" "$baseline"

echo "seeding a regression: removing the bearer-over-HTTP /api/orders RRPairs from the baseline"
removed="$(python3 - "$baseline" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
internal_re = re.compile(r"json:\s*(\{.*\})", re.S)
removed = 0
for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    text = path.read_text(errors="ignore")
    m = internal_re.search(text)
    if not m:
        continue
    try:
        rr = json.loads(m.group(1))
    except Exception:
        continue
    if rr.get("direction") != "IN":
        continue
    uri = rr.get("http", {}).get("req", {}).get("uri", "")
    if uri.startswith("/api/orders"):
        path.unlink()
        removed += 1
print(removed)
PY
)"
[[ "$removed" -ge 1 ]] || die "expected to remove at least 1 orders RRPair from baseline, removed $removed"

echo "running compare: baseline (no orders) -> current (full recording)"
"$compare_script" \
  --in "$current" \
  --baseline "$baseline" \
  --out-dir "$tmp/compare" >"$tmp/compare.out" 2>&1 || { cat "$tmp/compare.out" >&2; die "compare exited nonzero"; }
cat "$tmp/compare.out"

for f in report.json report.html report.prompt.md; do
  [[ -s "$tmp/compare/$f" ]] || die "compare did not write $f"
done

regressed="$(python3 - "$tmp/compare/report.prompt.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^##\s+What regressed\s*\n(.*?)(?=^##\s|\Z)", text, re.S | re.M)
body = m.group(1).strip() if m else ""
print(sum(1 for ln in body.splitlines() if ln.strip().startswith("- ")))
PY
)"
[[ "$regressed" -ge 1 ]] || die "compare did not detect the seeded regression (regressed=$regressed)"
echo "detected $regressed regression finding(s)"

echo "running compare of the recording against itself (expect no regression)"
"$compare_script" \
  --in "$recording" \
  --baseline "$recording" \
  --out-dir "$tmp/same" \
  --fail-on-regression >"$tmp/same.out" 2>&1 || { cat "$tmp/same.out" >&2; die "self-compare should not fail on regression"; }

echo "PASS: removed=$removed regressed=$regressed report files written; self-compare clean"
