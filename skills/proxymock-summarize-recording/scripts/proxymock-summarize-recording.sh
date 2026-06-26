#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-summarize-recording.sh --in DIR [options]

Summarize a proxymock recording: enumerate hosts/services, inbound and outbound
endpoints, methods, status-code distribution, and request volume, then append
proxymock's own report digest (findings + recommendations). Writes one markdown
brief.

Required:
  --in DIR             Recording / RRPair directory to summarize

Options:
  --out FILE           Markdown summary path (default: <work>/summary.md)
  --work-dir DIR       Directory for the summary and the raw report digest
  --no-report          Skip the `proxymock report` digest (structure only)
  --proxymock PATH     proxymock binary (default: proxymock from PATH)
  -h, --help           Show this help

Examples:
  proxymock-summarize-recording.sh --in ./proxymock/recording
  proxymock-summarize-recording.sh --in ./lab/proxymock/recording --out brief.md
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
out_file=""
work_dir=""
do_report="1"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out requires a value"; out_file="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --no-report) do_report="0"; shift ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
command -v python3 >/dev/null 2>&1 || die "missing required command: python3"
if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

in_dir="$(abs_path "$in_dir")"
if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-summary-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"
[[ -n "$out_file" ]] || out_file="$work_dir/summary.md"
mkdir -p "$(dirname "$out_file")"

report_digest=""
if [[ "$do_report" == "1" ]]; then
  report_digest="$work_dir/report.prompt.md"
  "$proxymock_bin" report --in "$in_dir" --format prompt --out "$report_digest" --exit-zero \
    || report_digest=""
fi

python3 - "$in_dir" "$out_file" "${report_digest:-}" <<'PY'
import json, os, pathlib, re, sys
from collections import Counter, defaultdict

root = pathlib.Path(sys.argv[1])
out_file = pathlib.Path(sys.argv[2])
report_digest = sys.argv[3] if len(sys.argv) > 3 else ""
internal_re = re.compile(r"json:\s*(\{.*\})", re.S)

def load_rr(path):
    text = path.read_text(errors="ignore")
    if path.suffix == ".json":
        return json.loads(text)
    m = internal_re.search(text)
    if not m:
        raise ValueError("no json block")
    return json.loads(m.group(1))

total = 0
by_direction = Counter()
hosts = Counter()
services = Counter()
protocols = Counter()
status = Counter()
status_class = Counter()
# endpoints keyed by (direction, method, host_or_service) -> Counter(path)
endpoints = defaultdict(Counter)

for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in {".md", ".json"}:
        continue
    try:
        rr = load_rr(path)
    except Exception:
        continue
    req = rr.get("http", {}).get("req", {})
    res = rr.get("http", {}).get("res", {})
    if not req and not res:
        continue
    total += 1
    direction = rr.get("direction") or "?"
    by_direction[direction] += 1
    host = req.get("host", "") or rr.get("netinfo", {}).get("upstream", {}).get("hostname", "")
    if host:
        hosts[host] += 1
    svc = rr.get("service", "")
    if svc:
        services[svc] += 1
    proto = (rr.get("l7protocol") or "").lower()
    if proto:
        protocols[proto] += 1
    code = res.get("statusCode")
    if isinstance(code, int) and code:
        status[code] += 1
        status_class[f"{code // 100}xx"] += 1
    method = req.get("method") or rr.get("command") or "?"
    uri = req.get("uri") or req.get("url") or rr.get("location") or ""
    # collapse trailing id-ish path segments so endpoints group cleanly
    norm = re.sub(r"/(?:[0-9a-fA-F-]{8,}|[0-9]+|[a-z0-9-]*[0-9][a-z0-9-]*)(?=/|$)", "/{id}", uri)
    key = (direction, method, host or svc or "")
    endpoints[key][norm] += 1

lines = []
lines.append(f"# Recording summary — `{root}`")
lines.append("")
lines.append(f"- **RRPairs:** {total}")
if by_direction:
    parts = ", ".join(f"{k} {v}" for k, v in sorted(by_direction.items()))
    lines.append(f"- **Direction:** {parts}  (IN = calls into your app, OUT = calls your app made)")
if protocols:
    lines.append(f"- **Protocols:** {', '.join(f'{k} {v}' for k, v in protocols.most_common())}")
if hosts:
    lines.append(f"- **Hosts:** {', '.join(f'{h} ({n})' for h, n in hosts.most_common())}")
if services:
    lines.append(f"- **Services:** {', '.join(f'{s} ({n})' for s, n in services.most_common())}")
if status_class:
    lines.append(f"- **Status mix:** {', '.join(f'{k} {v}' for k, v in sorted(status_class.items()))}")
    detail = ", ".join(f"{c}×{n}" for c, n in sorted(status.items()))
    lines.append(f"  - codes: {detail}")
lines.append("")

dir_label = {"IN": "Inbound endpoints (requests to your app)",
             "OUT": "Outbound endpoints (calls your app makes)"}
for direction in ("IN", "OUT"):
    keys = [k for k in endpoints if k[0] == direction]
    if not keys:
        continue
    lines.append(f"## {dir_label.get(direction, direction)}")
    rows = []
    for (d, method, where) in keys:
        for pathn, n in endpoints[(d, method, where)].most_common():
            rows.append((where, method, pathn, n))
    for where, method, pathn, n in sorted(rows, key=lambda r: (r[0], r[1], r[2])):
        loc = f"`{where}` " if where else ""
        lines.append(f"- {loc}`{method} {pathn}` — {n}")
    lines.append("")

if report_digest and os.path.exists(report_digest):
    digest = pathlib.Path(report_digest).read_text(errors="ignore").strip()
    if digest:
        lines.append("## Findings & recommendations (proxymock report)")
        lines.append("")
        lines.append(digest)
        lines.append("")

out_file.write_text("\n".join(lines) + "\n")

# headline to stdout
print(f"summarized {total} RRPairs across {len(hosts)} host(s)")
if status_class:
    print("status: " + ", ".join(f"{k} {v}" for k, v in sorted(status_class.items())))
print(f"summary: {out_file}")
PY

echo "summary: $out_file"
