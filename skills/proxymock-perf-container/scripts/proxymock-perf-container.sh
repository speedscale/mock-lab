#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-perf-container.sh --in DIR --test-against URL [options]

Answer "what can THIS container sustain, and is it within budget?" for a single
service with its downstream mocked. Drives the proxymock-load-test skill's
script once per virtual-user ladder level, samples generator/app/host CPU
during every run, detects the throughput knee, and evaluates rps/p99
assertions at the knee with margins. Refuses to report a level where the load
harness saturated the host as an app limit.

Required:
  --in DIR             Recording dir of RRPair files to replay (inbound traffic)
  --test-against URL   Target to load (e.g. http://localhost:8080)

Options:
  --vus-ladder LIST    Comma-separated ascending VU levels (default: 1,4,16,50)
  --for DURATION       Duration per ladder level (default: 30s)
  --assert-rps N       Assert sustainable throughput >= N rps at the knee
  --assert-p99 N[ms]   Assert p99 latency <= N ms at the knee
  --margin-pct N       Margin applied to assertions (default: 10)
  --repeats N          Total samples at the assertion level; the WORST sample
                       gates pass/fail (default: 2)
  --pin-vus N          Evaluate assertions at this ladder level instead of the
                       detected knee (must be a ladder member)
  --no-performance     Disable the default high-throughput replay mode. By
                       default every load run passes --performance to the
                       load-test script (proxymock replay --performance): match
                       scoring is skipped, so rps/p99 describe pure load with
                       no scoring overhead on the generator, and matchPct is
                       reported as null / "not scored". This skill never gates
                       on matchPct, so the default costs nothing; opt out only
                       if you want match rates in the ladder report.
  --work-dir DIR       Where to write per-level runs and summary.json
  --load-test-script P Path to proxymock-load-test.sh (default: the sibling
                       proxymock-load-test skill's script)
  --proxymock PATH     proxymock binary, forwarded to the load-test script
  -h, --help           Show this help

Exit codes:
  0  assertions pass, or no assertions given (report-only)
  2  an assertion failed at the assertion level
  3  the assertion level is harness-bound: the numbers cannot support an
     app-limit claim (distinct from a failed assertion)
  4  precondition failure (bad args, missing dirs, a load run did not complete)

Test hooks (proof/testing only, both clearly non-production):
  PERF_FORCE_HARNESS_BOUND=1  force every level harness-bound. The real gate
                              cannot be forced hermetically without saturating
                              the host.
  PERF_FORCE_HARNESS_CLEAN=1  force every level clean. The real gate cannot be
                              suppressed hermetically on a host that is busy
                              with unrelated work.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 4
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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

# Honesty-gate constants (from the Tier 3 experiment):
# - a level is harness-bound when host idle drops under 20%, or the generator
#   burns at least a full core AND more than 2x the app's CPU (the full-core
#   floor keeps near-idle low-VU levels from tripping the ratio test)
# - the knee is the first level whose rps gain over the previous level is
#   under 10%
# - default assertion margin 10% covers the measured 4.8% rps spread across
#   repeat runs at a fixed VU level
idle_threshold=20
gen_factor=2
gen_core_floor=100
knee_gain_pct=10

in_dir=""
target=""
vus_ladder="1,4,16,50"
for_dur="30s"
assert_rps=""
assert_p99=""
margin_pct="10"
repeats="2"
pin_vus=""
work_dir=""
load_script=""
proxymock_bin=""
performance="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --test-against) [[ $# -ge 2 ]] || die "--test-against requires a value"; target="$2"; shift 2 ;;
    --vus-ladder) [[ $# -ge 2 ]] || die "--vus-ladder requires a value"; vus_ladder="$2"; shift 2 ;;
    --for) [[ $# -ge 2 ]] || die "--for requires a value"; for_dur="$2"; shift 2 ;;
    --assert-rps) [[ $# -ge 2 ]] || die "--assert-rps requires a value"; assert_rps="$2"; shift 2 ;;
    --assert-p99) [[ $# -ge 2 ]] || die "--assert-p99 requires a value"; assert_p99="${2%ms}"; shift 2 ;;
    --margin-pct) [[ $# -ge 2 ]] || die "--margin-pct requires a value"; margin_pct="$2"; shift 2 ;;
    --repeats) [[ $# -ge 2 ]] || die "--repeats requires a value"; repeats="$2"; shift 2 ;;
    --pin-vus) [[ $# -ge 2 ]] || die "--pin-vus requires a value"; pin_vus="$2"; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir requires a value"; work_dir="$2"; shift 2 ;;
    --load-test-script) [[ $# -ge 2 ]] || die "--load-test-script requires a value"; load_script="$2"; shift 2 ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    --performance) performance="1"; shift ;;
    --no-performance) performance="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -n "$target" ]] || die "--test-against is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"

need_cmd python3
need_cmd ps
need_cmd pgrep

# This skill builds on proxymock-load-test: each ladder level is one run of
# that skill's script, so replay flags and summary parsing live in one place.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$load_script" ]]; then
  load_script="$script_dir/../../proxymock-load-test/scripts/proxymock-load-test.sh"
fi
[[ -x "$load_script" ]] || die "proxymock-load-test script not found or not executable: $load_script (copy the proxymock-load-test skill alongside this one, or pass --load-test-script)"
load_script="$(abs_path "$load_script")"

[[ "$vus_ladder" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "--vus-ladder must be comma-separated integers: $vus_ladder"
IFS=',' read -r -a ladder <<<"$vus_ladder"
prev=0
for v in "${ladder[@]}"; do
  [[ "$v" -gt 0 ]] || die "--vus-ladder levels must be positive: $v"
  [[ "$v" -gt "$prev" ]] || die "--vus-ladder must be strictly ascending: $vus_ladder"
  prev="$v"
done

[[ "$repeats" =~ ^[0-9]+$ && "$repeats" -ge 1 ]] || die "--repeats must be a positive integer"
[[ -z "$assert_rps" || "$assert_rps" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--assert-rps must be a number: $assert_rps"
[[ -z "$assert_p99" || "$assert_p99" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--assert-p99 must be a number of milliseconds: $assert_p99"
[[ "$margin_pct" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--margin-pct must be a number: $margin_pct"

if [[ -n "$pin_vus" ]]; then
  found=0
  for v in "${ladder[@]}"; do
    [[ "$v" == "$pin_vus" ]] && found=1
  done
  [[ "$found" == "1" ]] || die "--pin-vus $pin_vus is not a --vus-ladder level ($vus_ladder); add it to the ladder"
fi

in_dir="$(abs_path "$in_dir")"
if [[ -z "$work_dir" ]]; then
  work_dir="proxymock-perf-container-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$work_dir"
work_dir="$(abs_path "$work_dir")"

# --- CPU attribution --------------------------------------------------------
# Parse the target host/port so the app process can be found by its listening
# socket. Non-local targets get no app CPU attribution (the generator-vs-app
# check is skipped; the host-idle check still applies to the generator host).
host_port="${target#*://}"
host_port="${host_port%%/*}"
target_host="${host_port%%:*}"
if [[ "$host_port" == *:* ]]; then
  target_port="${host_port##*:}"
else
  case "$target" in
    https://*) target_port=443 ;;
    *) target_port=80 ;;
  esac
fi
app_local=0
case "$target_host" in
  localhost|127.0.0.1|::1|\[::1\]|0.0.0.0) app_local=1 ;;
esac
if [[ "$app_local" == "0" ]]; then
  echo "warning: target host '$target_host' is not local; app CPU is unmeasurable and the generator-vs-app check is skipped" >&2
elif ! command -v lsof >/dev/null 2>&1; then
  app_local=0
  echo "warning: lsof not found; app CPU is unmeasurable and the generator-vs-app check is skipped" >&2
fi

platform="$(uname -s)"

host_idle_pct() {
  if [[ "$platform" == "Darwin" ]]; then
    # first top sample is cumulative since boot; the second is the real interval
    top -l 2 -n 0 -s 1 2>/dev/null | grep 'CPU usage' | tail -1 \
      | sed -nE 's/.* ([0-9.]+)% idle.*/\1/p' || true
  else
    python3 - <<'PY' 2>/dev/null || true
import time
def snap():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    idle = v[3] + (v[4] if len(v) > 4 else 0)
    return idle, sum(v)
i1, t1 = snap()
time.sleep(1)
i2, t2 = snap()
print(f"{100.0 * (i2 - i1) / max(1, t2 - t1):.1f}")
PY
  fi
}

# Cumulative CPU seconds for a comma-separated pid list. CPU rates are
# computed later as cputime deltas between samples: ps's %cpu column is a
# decaying lifetime average that badly under-reports a long-lived app under a
# short burst (measured: an app serving 4k rps read 1%), while cputime deltas
# are exact on both platforms.
cputime_of_pids() {
  local pids="$1"
  if [[ -z "$pids" ]]; then
    echo ""
    return 0
  fi
  ps -o time= -p "$pids" 2>/dev/null | awk '
    { n = split($1, a, ":")
      s = 0
      if (n == 3) { d = 0; h = a[1]
        if (index(h, "-") > 0) { split(h, b, "-"); d = b[1]; h = b[2] }
        s = ((d * 24 + h) * 60 + a[2]) * 60 + a[3]
      } else if (n == 2) { s = a[1] * 60 + a[2] }
      total += s }
    END { if (NR > 0) printf "%.2f", total }' || true
}

# Generator pids = processes whose command line contains "proxymock replay"
# AND that descend from this run's load-test script. The descendant filter
# keeps concurrent proxymock sessions elsewhere on the host from polluting
# attribution (observed in practice: another session's replay at 600% CPU).
gen_pids_of_run() {
  local root="$1"
  { ps -eo pid=,ppid= 2>/dev/null; echo "---"; pgrep -f 'proxymock replay' 2>/dev/null; } \
    | python3 -c '
import sys
root = int(sys.argv[1])
lines = sys.stdin.read().splitlines()
sep = lines.index("---")
kids = {}
for line in lines[:sep]:
    parts = line.split()
    if len(parts) >= 2:
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        kids.setdefault(ppid, []).append(pid)
cand = {int(l.strip()) for l in lines[sep + 1:] if l.strip().isdigit()}
desc = set()
stack = [root]
while stack:
    for c in kids.get(stack.pop(), []):
        if c not in desc:
            desc.add(c)
            stack.append(c)
print(",".join(str(p) for p in sorted(cand & desc)))
' "$root" 2>/dev/null || true
}

# Samples generator/app cputime roughly every 0.7s while a load run is in
# flight. CSV line: epoch,gen_cputime_s,app_cputime_s (empty field =
# unmeasurable at that instant). Host idle runs in its own loop because each
# idle measurement blocks ~1s (top interval / /proc/stat delta) and would
# starve the cputime cadence that short runs need for deltas.
sample_cpu_loop() {
  local out="$1" load_pid="$2"
  local ts gen_pids app_pids gen_t app_t
  while :; do
    ts="$(python3 -c 'import time; print(f"{time.time():.2f}")' 2>/dev/null || true)"
    gen_pids="$(gen_pids_of_run "$load_pid")"
    gen_t="$(cputime_of_pids "$gen_pids")"
    app_t=""
    if [[ "$app_local" == "1" ]]; then
      app_pids="$(lsof -nP -ti "tcp:${target_port}" -sTCP:LISTEN 2>/dev/null | sort -u | paste -sd, - || true)"
      app_t="$(cputime_of_pids "$app_pids")"
    fi
    echo "${ts},${gen_t},${app_t}" >>"$out" || true
    sleep 0.5
  done
}

sample_idle_loop() {
  local out="$1"
  local idle
  while :; do
    idle="$(host_idle_pct)"   # takes ~1s on both platforms; paces the loop
    [[ -n "$idle" ]] && echo "$idle" >>"$out"
    sleep 0.2
  done
}

run_level() {
  local vus="$1" outdir="$2"
  mkdir -p "$outdir"
  local samples="$outdir/cpu-samples.csv"
  local idle_samples="$outdir/idle-samples.csv"
  : >"$samples"
  : >"$idle_samples"
  echo "level VU=${vus}: replaying for ${for_dur} against ${target}"
  local rc=0
  local lt_args=(--in "$in_dir" --test-against "$target" --vus "$vus" --for "$for_dur" --work-dir "$outdir/load")
  if [[ "$performance" == "1" ]]; then
    lt_args+=(--performance)
  fi
  if [[ -n "$proxymock_bin" ]]; then
    lt_args+=(--proxymock "$proxymock_bin")
  fi
  "$load_script" "${lt_args[@]}" >"$outdir/load.out" 2>&1 &
  local load_pid=$!
  sample_cpu_loop "$samples" "$load_pid" &
  local cpu_sampler_pid=$!
  sample_idle_loop "$idle_samples" &
  local idle_sampler_pid=$!
  wait "$load_pid" || rc=$?
  kill "$cpu_sampler_pid" "$idle_sampler_pid" 2>/dev/null || true
  wait "$cpu_sampler_pid" 2>/dev/null || true
  wait "$idle_sampler_pid" 2>/dev/null || true
  if [[ "$rc" -ne 0 || ! -s "$outdir/load/summary.json" ]]; then
    cat "$outdir/load.out" >&2
    die "load run at VU=${vus} did not complete (exit ${rc}); see ${outdir}/load.out"
  fi
}

# --- phase 1: walk the ladder ------------------------------------------------
for v in "${ladder[@]}"; do
  run_level "$v" "$work_dir/vus-$v"
done

# --- phase 2: attribute CPU per level and find the knee ----------------------
assert_vus="$(python3 - "$work_dir" "$vus_ladder" "$knee_gain_pct" "$idle_threshold" "$gen_factor" "$gen_core_floor" "$pin_vus" <<'PY'
import json, os, sys

work, levels_csv, knee_thr, idle_thr, gen_factor, gen_floor, pin = sys.argv[1:8]
levels = [int(x) for x in levels_csv.split(",")]
knee_thr = float(knee_thr)
idle_thr = float(idle_thr)
gen_factor = float(gen_factor)
gen_floor = float(gen_floor)
pin = int(pin) if pin else None
force_bound = os.environ.get("PERF_FORCE_HARNESS_BOUND") == "1"
force_clean = os.environ.get("PERF_FORCE_HARNESS_CLEAN") == "1"


def read_cpu(cpu_path, idle_path):
    # cpu csv rows: epoch,gen_cputime_s,app_cputime_s; CPU rates are cputime
    # deltas between consecutive samples (see cputime_of_pids). idle file:
    # one host-idle percentage per line, sampled independently.
    rows = []
    try:
        lines = open(cpu_path).read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        ts, g, a = (line.split(",") + [""] * 3)[:3]
        rows.append((float(ts) if ts else None, float(g) if g else None,
                     float(a) if a else None))
    gen_max = app_max = idle_min = None
    for (t1, g1, a1), (t2, g2, a2) in zip(rows, rows[1:]):
        if t1 is None or t2 is None or t2 <= t1:
            continue
        dt = t2 - t1
        if g1 is not None and g2 is not None and g2 >= g1:
            gen_max = max(gen_max or 0.0, (g2 - g1) / dt * 100.0)
        if a1 is not None and a2 is not None and a2 >= a1:
            app_max = max(app_max or 0.0, (a2 - a1) / dt * 100.0)
    try:
        idle_lines = open(idle_path).read().splitlines()
    except OSError:
        idle_lines = []
    for line in idle_lines:
        line = line.strip()
        if line:
            v = float(line)
            idle_min = v if idle_min is None else min(idle_min, v)
    return {"generatorMaxPct": gen_max, "appMaxPct": app_max,
            "hostIdleMinPct": idle_min, "samples": len(rows)}


def harness(cpu):
    if force_bound:
        return True, "forced by PERF_FORCE_HARNESS_BOUND"
    if force_clean:
        return False, ""
    reasons = []
    idle, gen, app = cpu["hostIdleMinPct"], cpu["generatorMaxPct"], cpu["appMaxPct"]
    if idle is not None and idle < idle_thr:
        reasons.append(f"host idle {idle:.0f}% < {idle_thr:.0f}%")
    if (gen is not None and app is not None
            and gen >= gen_floor and gen > gen_factor * app):
        reasons.append(f"generator {gen:.0f}% CPU > {gen_factor:.0f}x app {app:.0f}%")
    return bool(reasons), "; ".join(reasons)


records = []
for v in levels:
    d = os.path.join(work, f"vus-{v}")
    s = json.load(open(os.path.join(d, "load", "summary.json")))
    cpu = read_cpu(os.path.join(d, "cpu-samples.csv"),
                   os.path.join(d, "idle-samples.csv"))
    hb, why = harness(cpu)
    records.append({
        "vus": v,
        "rps": s.get("rps"),
        "totalRequests": s.get("totalRequests"),
        "failed": s.get("failed"),
        "matchPct": s.get("matchPct"),
        "latencyMs": s.get("latencyMs") or {},
        "cpu": cpu,
        "harnessBound": hb,
        "harnessReason": why or None,
        "runDir": d,
    })

# knee detection over CLEAN levels only: harness-bound levels can never back
# an app-limit claim
clean = [r for r in records
         if not r["harnessBound"] and isinstance(r.get("rps"), (int, float))]
knee = None
plateau = False
if clean:
    knee = clean[-1]
    for i in range(1, len(clean)):
        prev, cur = clean[i - 1], clean[i]
        gain = (cur["rps"] - prev["rps"]) / prev["rps"] * 100.0 if prev["rps"] else 0.0
        if gain < knee_thr:
            knee = prev
            plateau = True
            break

assert_vus = pin if pin is not None else (knee["vus"] if knee else None)
out = {
    "levels": records,
    "kneeVus": knee["vus"] if knee else None,
    "plateauObserved": plateau,
    "assertVus": assert_vus,
    "cleanMaxVus": clean[-1]["vus"] if clean else None,
}
with open(os.path.join(work, "ladder.json"), "w") as f:
    json.dump(out, f, indent=2)
print(assert_vus if assert_vus is not None else "")
PY
)"

# --- phase 3: repeat runs at the assertion level (worst sample gates) --------
if [[ -n "$assert_vus" && "$repeats" -gt 1 ]]; then
  for ((i = 2; i <= repeats; i++)); do
    echo "repeat ${i}/${repeats} at VU=${assert_vus}"
    run_level "$assert_vus" "$work_dir/repeat-$i"
  done
fi

# --- phase 4: verdicts, summary.json, exit code ------------------------------
final_rc=0
python3 - "$work_dir" "$repeats" "$assert_rps" "$assert_p99" "$margin_pct" "$idle_threshold" "$gen_factor" "$gen_core_floor" "$target" <<'PY' || final_rc=$?
import json, os, sys

work, repeats, assert_rps, assert_p99, margin, idle_thr, gen_factor, gen_floor, target = sys.argv[1:10]
repeats = int(repeats)
assert_rps = float(assert_rps) if assert_rps else None
assert_p99 = float(assert_p99) if assert_p99 else None
margin = float(margin)
idle_thr = float(idle_thr)
gen_factor = float(gen_factor)
gen_floor = float(gen_floor)
force_bound = os.environ.get("PERF_FORCE_HARNESS_BOUND") == "1"
force_clean = os.environ.get("PERF_FORCE_HARNESS_CLEAN") == "1"


def read_cpu(cpu_path, idle_path):
    rows = []
    try:
        lines = open(cpu_path).read().splitlines()
    except OSError:
        lines = []
    for line in lines:
        ts, g, a = (line.split(",") + [""] * 3)[:3]
        rows.append((float(ts) if ts else None, float(g) if g else None,
                     float(a) if a else None))
    gen_max = app_max = idle_min = None
    for (t1, g1, a1), (t2, g2, a2) in zip(rows, rows[1:]):
        if t1 is None or t2 is None or t2 <= t1:
            continue
        dt = t2 - t1
        if g1 is not None and g2 is not None and g2 >= g1:
            gen_max = max(gen_max or 0.0, (g2 - g1) / dt * 100.0)
        if a1 is not None and a2 is not None and a2 >= a1:
            app_max = max(app_max or 0.0, (a2 - a1) / dt * 100.0)
    try:
        idle_lines = open(idle_path).read().splitlines()
    except OSError:
        idle_lines = []
    for line in idle_lines:
        line = line.strip()
        if line:
            v = float(line)
            idle_min = v if idle_min is None else min(idle_min, v)
    return {"generatorMaxPct": gen_max, "appMaxPct": app_max,
            "hostIdleMinPct": idle_min, "samples": len(rows)}


def harness(cpu):
    if force_bound:
        return True, "forced by PERF_FORCE_HARNESS_BOUND"
    if force_clean:
        return False, ""
    reasons = []
    idle, gen, app = cpu["hostIdleMinPct"], cpu["generatorMaxPct"], cpu["appMaxPct"]
    if idle is not None and idle < idle_thr:
        reasons.append(f"host idle {idle:.0f}% < {idle_thr:.0f}%")
    if (gen is not None and app is not None
            and gen >= gen_floor and gen > gen_factor * app):
        reasons.append(f"generator {gen:.0f}% CPU > {gen_factor:.0f}x app {app:.0f}%")
    return bool(reasons), "; ".join(reasons)


ladder = json.load(open(os.path.join(work, "ladder.json")))
levels = ladder["levels"]
by_vus = {r["vus"]: r for r in levels}
assert_vus = ladder["assertVus"]
knee_vus = ladder["kneeVus"]
clean_max = ladder["cleanMaxVus"]

samples = []
if assert_vus is not None:
    base = by_vus[assert_vus]
    samples.append({"run": base["runDir"], "rps": base["rps"],
                    "p99Ms": base["latencyMs"].get("p99"), "cpu": base["cpu"],
                    "harnessBound": base["harnessBound"],
                    "harnessReason": base["harnessReason"]})
    for i in range(2, repeats + 1):
        d = os.path.join(work, f"repeat-{i}")
        p = os.path.join(d, "load", "summary.json")
        if not os.path.isfile(p):
            break
        s = json.load(open(p))
        cpu = read_cpu(os.path.join(d, "cpu-samples.csv"),
                   os.path.join(d, "idle-samples.csv"))
        hb, why = harness(cpu)
        samples.append({"run": d, "rps": s.get("rps"),
                        "p99Ms": (s.get("latencyMs") or {}).get("p99"),
                        "cpu": cpu, "harnessBound": hb,
                        "harnessReason": why or None})

rps_vals = [s["rps"] for s in samples if isinstance(s["rps"], (int, float))]
p99_vals = [s["p99Ms"] for s in samples if isinstance(s["p99Ms"], (int, float))]
worst_rps = min(rps_vals) if rps_vals else None
worst_p99 = max(p99_vals) if p99_vals else None
level_bound = any(s["harnessBound"] for s in samples) if samples else True

bound = [r["vus"] for r in levels if r["harnessBound"]]
if bound and clean_max is None:
    harness_note = "harness-bound at every tested level; no app-limit claim possible"
elif bound and all(v > clean_max for v in bound):
    harness_note = f"harness-bound above VU~{clean_max}"
elif bound:
    harness_note = "harness-bound at VU " + ",".join(str(v) for v in sorted(bound))
else:
    harness_note = None

# integer-ms percentile granularity: below 5ms, p50/p95 deltas are rounding
# artifacts; rps and p99 are the only meaningful gates (this skill offers no
# other assertions by design)
sub5 = worst_p99 is not None and worst_p99 < 5

have_asserts = assert_rps is not None or assert_p99 is not None
verdict_rps = verdict_p99 = None
if assert_rps is not None:
    if worst_rps is None:
        verdict_rps = "unevaluable"
    else:
        verdict_rps = "pass" if worst_rps >= assert_rps * (1 - margin / 100.0) else "fail"
if assert_p99 is not None:
    if worst_p99 is None:
        verdict_p99 = "unevaluable"
    else:
        verdict_p99 = "pass" if worst_p99 <= assert_p99 * (1 + margin / 100.0) else "fail"

exit_code = 0
if have_asserts:
    if assert_vus is None or level_bound:
        exit_code = 3
    elif "fail" in (verdict_rps, verdict_p99) or "unevaluable" in (verdict_rps, verdict_p99):
        exit_code = 2

knee = None
if knee_vus is not None:
    k = by_vus[knee_vus]
    knee = {"vus": knee_vus, "rps": k["rps"], "p99Ms": k["latencyMs"].get("p99"),
            "plateauObserved": ladder["plateauObserved"]}

summary = {
    "target": target,
    "ladder": levels,
    "knee": knee,
    "assertLevel": None if assert_vus is None else {
        "vus": assert_vus,
        "samples": samples,
        "worstRps": worst_rps,
        "worstP99Ms": worst_p99,
        "harnessBound": level_bound,
    },
    "harnessNote": harness_note,
    "subFiveMsGranularity": sub5,
    "assertions": {
        "marginPct": margin,
        "rps": None if assert_rps is None else {"min": assert_rps, "verdict": verdict_rps},
        "p99Ms": None if assert_p99 is None else {"max": assert_p99, "verdict": verdict_p99},
    },
    "exitCode": exit_code,
    "workDir": work,
}
summary_path = os.path.join(work, "summary.json")
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=True)
    f.write("\n")


def fnum(v, fmt="{:.1f}"):
    return fmt.format(v) if isinstance(v, (int, float)) else "n/a"


print("\n=== perf-container summary ===")
print(f"target     : {target}")
print("ladder     :")
for r in levels:
    lat = r["latencyMs"]
    cpu = r["cpu"]
    # matchPct is null when the load run used --performance (match scoring
    # skipped); print "not scored" rather than a fake percentage
    match_s = (f"{r['matchPct']:.1f}%"
               if isinstance(r["matchPct"], (int, float)) else "not scored")
    line = (f"  VU {r['vus']:<4}: {fnum(r['rps'])} rps  "
            f"p50={lat.get('p50')} p95={lat.get('p95')} p99={lat.get('p99')} ms  "
            f"failed={r['failed']}  match={match_s}  "
            f"gen={fnum(cpu['generatorMaxPct'], '{:.0f}')}% "
            f"app={fnum(cpu['appMaxPct'], '{:.0f}')}% "
            f"idle={fnum(cpu['hostIdleMinPct'], '{:.0f}')}%")
    if r["harnessBound"]:
        line += f"  [HARNESS-BOUND: {r['harnessReason']}]"
    print(line)
if knee:
    tag = "plateau observed" if knee["plateauObserved"] else "no plateau within ladder; true knee may be higher"
    print(f"knee       : VU {knee['vus']} ({tag})")
    print(f"sustainable: ~{fnum(knee['rps'])} rps at VU {knee['vus']} (p99 {knee['p99Ms']} ms)")
else:
    print("knee       : indeterminate")
    print("sustainable: no app-limit claim possible from this run")
if harness_note:
    print(f"harness    : {harness_note}")
if assert_vus is not None and len(samples) > 1:
    print(f"samples    : {len(samples)} at VU {assert_vus}; worst rps {fnum(worst_rps)}, worst p99 {worst_p99} ms (worst sample gates)")
if sub5:
    print("note       : p99 at the assertion level is under 5 ms; integer-ms percentiles are coarse there, so only rps and p99 are gated (p50/p95 deltas are granularity artifacts)")
if assert_rps is not None:
    print(f"assert rps : >= {assert_rps} with {margin:.0f}% margin -> {verdict_rps.upper()} (worst {fnum(worst_rps)})")
if assert_p99 is not None:
    print(f"assert p99 : <= {assert_p99} ms with {margin:.0f}% margin -> {verdict_p99.upper()} (worst {worst_p99})")
if exit_code == 3:
    print("verdict    : HARNESS-BOUND at the assertion level; the result cannot answer the assertion (exit 3)")
print(f"summary    : {summary_path}")
sys.exit(exit_code)
PY

exit "$final_rc"
