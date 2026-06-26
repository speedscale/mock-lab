#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-compare-results.sh --in DIR [--baseline DIR] [options]

Run a deep proxymock report over a set of RRPairs and, when a baseline is
given, a Compare report showing what regressed / improved / persisted across
Performance, Reliability, and Security. Writes report files to disk.

Required:
  --in DIR             Current RRPair directory to report on (e.g. a fresh
                       replay output, or a recording)

Options:
  --baseline DIR       Baseline RRPair directory. When set, output is a
                       before/after Compare report.
  --out-dir DIR        Where to write report files (default: timestamped dir)
  --drift              Also run `proxymock drift` between baseline and current
                       (requires --baseline) to list fields whose values vary
  --sensitivity TIER   drift tier: permissive | normal | strict (default normal)
  --fail-on-regression Exit nonzero if the Compare report lists any regression
  --proxymock PATH     proxymock binary (default: proxymock from PATH)
  -h, --help           Show this help

Output files (in --out-dir):
  report.json          machine-readable report
  report.html          self-contained HTML report (open in a browser)
  report.prompt.md     LLM-pasteable markdown digest (~2-4 KB)
  drift.json           (only with --drift) DriftReport with prefilled transforms

Examples:
  # single report over one recording
  proxymock-compare-results.sh --in ./proxymock/recording

  # before/after: did anything regress between two replay runs?
  proxymock-compare-results.sh \
    --in ./proxymock/results/replayed-after \
    --baseline ./proxymock/results/replayed-before \
    --drift --fail-on-regression
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
  fi
}

in_dir=""
baseline_dir=""
out_dir=""
do_drift="0"
sensitivity="normal"
fail_on_regression="0"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || die "--baseline requires a value"; baseline_dir="$2"; shift 2 ;;
    --out-dir) [[ $# -ge 2 ]] || die "--out-dir requires a value"; out_dir="$2"; shift 2 ;;
    --drift) do_drift="1"; shift ;;
    --sensitivity) [[ $# -ge 2 ]] || die "--sensitivity requires a value"; sensitivity="$2"; shift 2 ;;
    --fail-on-regression) fail_on_regression="1"; shift ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
[[ -z "$baseline_dir" || -d "$baseline_dir" ]] || die "--baseline is not a directory: $baseline_dir"
[[ "$do_drift" == "0" || -n "$baseline_dir" ]] || die "--drift requires --baseline"

if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

in_dir="$(abs_path "$in_dir")"
[[ -n "$baseline_dir" ]] && baseline_dir="$(abs_path "$baseline_dir")"

if [[ -z "$out_dir" ]]; then
  out_dir="proxymock-compare-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out_dir"
out_dir="$(abs_path "$out_dir")"

base_args=(report --in "$in_dir")
if [[ -n "$baseline_dir" ]]; then
  base_args+=(--baseline "$baseline_dir")
  echo "comparing: baseline=${baseline_dir} -> current=${in_dir}"
else
  echo "reporting on: ${in_dir}"
fi

for fmt in json html prompt; do
  case "$fmt" in
    json) out="$out_dir/report.json" ;;
    html) out="$out_dir/report.html" ;;
    prompt) out="$out_dir/report.prompt.md" ;;
  esac
  "$proxymock_bin" "${base_args[@]}" --format "$fmt" --out "$out" --exit-zero
done

drift_json=""
if [[ "$do_drift" == "1" ]]; then
  drift_json="$out_dir/drift.json"
  echo "computing drift (${sensitivity})"
  "$proxymock_bin" drift \
    --source "$baseline_dir" \
    --source "$in_dir" \
    --sensitivity "$sensitivity" \
    --out "$drift_json"
fi

echo ""
echo "report files: $out_dir"
ls -1 "$out_dir"

# Parse the prompt digest for the compare verdict; it is stable across versions.
regressions=0
if [[ -n "$baseline_dir" ]]; then
  echo ""
  echo "=== compare verdict ==="
  regressions="$(python3 - "$out_dir/report.prompt.md" <<'PY'
import re, sys
text = open(sys.argv[1]).read()

def section(title):
    # capture body of "## <title>" up to the next "## " or EOF
    m = re.search(r"^##\s+" + re.escape(title) + r"\s*\n(.*?)(?=^##\s|\Z)", text, re.S | re.M)
    return (m.group(1).strip() if m else "")

def bullets(body):
    return [ln for ln in body.splitlines() if ln.strip().startswith("- ")]

regressed = section("What regressed")
improved = section("What improved")
persisted = section("Still present (high severity, survived both runs)")

n_reg = len(bullets(regressed))
n_imp = len(bullets(improved))
n_per = len(bullets(persisted))

print(f"regressed: {n_reg}", file=sys.stderr)
print(f"improved : {n_imp}", file=sys.stderr)
print(f"persisted: {n_per}", file=sys.stderr)
print(n_reg)
PY
)"
fi

echo "digest: $out_dir/report.prompt.md"
echo "open  : $out_dir/report.html"
[[ -n "$drift_json" ]] && echo "drift : $drift_json"

if [[ "$fail_on_regression" == "1" && -n "$baseline_dir" && "${regressions:-0}" -gt 0 ]]; then
  echo "FAIL: ${regressions} regression(s) detected" >&2
  exit 1
fi
