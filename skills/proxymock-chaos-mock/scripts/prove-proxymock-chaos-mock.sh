#!/usr/bin/env bash
# Proves: native --fault injection serves the documented behavior straight off
# the UNMODIFIED committed recording - status faults, a Retry-After header, an
# exact deterministic rate=F/N ratio, per-endpoint latency, the chaos response
# header, and a fault-free downstream after --restore - and that both silent
# traps are gated: a pattern matching nothing exits 2, and a connection= fault
# against HTTP/2 pairs exits 5 instead of being silently ignored.
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
chaos_script="$script_dir/proxymock-chaos-mock.sh"

need_cmd curl
need_cmd proxymock
need_cmd python3
need_cmd lsof
[[ -x "$chaos_script" ]] || die "chaos script is not executable: $chaos_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-chaos-proof.$$"
pids=()
ports=()
# --serve backgrounds a mock the script does not own; ql_prove_cleanup sweeps
# our ports so nothing this proof started outlives it
trap ql_prove_cleanup EXIT
mkdir -p "$tmp"

# every recorded downstream URI is reachable through the mock's proxy port with
# a direct proxy curl (plain http scheme; the mock matches on signature)
downstream="http://demo-api.trafficreplay.com"
port=""
health=""

proxy_curl() {
  # proxy_curl PATH -> status code
  curl -s -o /dev/null -m 10 -w '%{http_code}' \
    -x "http://127.0.0.1:$port" "${downstream}$1"
}

serve_chaos() {
  # serve_chaos NAME ARGS...: start a faulted mock on fresh ports
  local name="$1"
  shift
  port="$(ql_pick_port)"
  health="$(ql_pick_port)"
  ports+=("$port" "$health")
  "$chaos_script" --in "$recording" --work-dir "$tmp/$name" --serve \
    --proxy-out-port "$port" --health-port "$health" "$@" \
    >"$tmp/$name.out" 2>&1 || {
      cat "$tmp/$name.out" >&2
      die "$name: --serve failed"
    }
}

echo "step 1: status fault on the unmodified recording, with the chaos header"
serve_chaos down --scenario down --target '/v1/projects'
[[ "$(proxy_curl /v1/projects)" == "503" ]] || die "down: target endpoint did not 503"
[[ "$(proxy_curl /v1/categories)" == "200" ]] || die "down: untargeted endpoint was not healthy"
curl -s -D- -o /dev/null -m 10 -x "http://127.0.0.1:$port" "${downstream}/v1/projects" \
  | grep -qi '^x-speedscale-chaos: proxymock fault' \
  || die "down: response is missing the x-speedscale-chaos header"
echo "  503 on the target, 200 elsewhere, chaos header present"

echo "step 2: restore puts a fault-free downstream back on the same port"
"$chaos_script" --restore --work-dir "$tmp/down" >"$tmp/restore.out" 2>&1 || {
  cat "$tmp/restore.out" >&2
  die "--restore failed"
}
for _ in 1 2 3; do
  [[ "$(proxy_curl /v1/projects)" == "200" ]] || die "restored mock still faulting"
done
echo "  healthy 200s after restore"
ql_sweep_port "$port"

echo "step 3: ratelimit injects 429 plus the Retry-After header"
serve_chaos ratelimit --scenario ratelimit --target '/v1/projects' --retry-after 30
[[ "$(proxy_curl /v1/projects)" == "429" ]] || die "ratelimit: no 429"
curl -s -D- -o /dev/null -m 10 -x "http://127.0.0.1:$port" "${downstream}/v1/projects" \
  | grep -qi '^retry-after: 30' || die "ratelimit: Retry-After header missing"
echo "  429 with Retry-After: 30"
ql_sweep_port "$port"

echo "step 4: flaky rate=1/3 is exact and periodic over 6 probes"
serve_chaos flaky --scenario flaky --target '/v1/categories' --ratio 1/3
seq_got=""
for _ in 1 2 3 4 5 6; do
  seq_got+="$(proxy_curl /v1/categories) "
done
[[ "$seq_got" == "503 200 200 503 200 200 " ]] \
  || die "rate=1/3 not exact: got '$seq_got'"
[[ "$(proxy_curl /v1/projects)" == "200" ]] \
  || die "flaky: untargeted endpoint was not healthy"
echo "  exact 1/3 periodicity confirmed: $seq_got"
ql_sweep_port "$port"

echo "step 5: latency fault delays only the target endpoint"
serve_chaos slow --scenario slow --target '/v1/categories' --latency 500ms
t="$(curl -s -o /dev/null -m 10 -w '%{time_total}' \
  -x "http://127.0.0.1:$port" "${downstream}/v1/categories")"
u="$(curl -s -o /dev/null -m 10 -w '%{time_total}' \
  -x "http://127.0.0.1:$port" "${downstream}/v1/projects")"
python3 - "$t" "$u" <<'PY'
import sys
t, u = float(sys.argv[1]), float(sys.argv[2])
assert t >= 0.5, f"target latency {t}s < configured 0.5s"
assert u < 0.5, f"untargeted endpoint also delayed: {u}s"
print(f"  target {t:.3f}s (>= 0.500s configured), untargeted {u:.3f}s")
PY
ql_sweep_port "$port"

echo "step 6: a pattern that matches nothing exits 2 instead of serving a no-op"
rc=0
"$chaos_script" --in "$recording" --scenario down \
  --target 'https://demo-api.trafficreplay.com:443/v1/projects' \
  --work-dir "$tmp/nomatch" >"$tmp/nomatch.out" 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || { cat "$tmp/nomatch.out" >&2; die "expected exit 2, got $rc"; }
grep -q 'SILENT no-op' "$tmp/nomatch.out" || die "exit 2 without the no-op warning"
grep -q 'no scheme, no port, no method' "$tmp/nomatch.out" \
  || die "exit 2 without the matching-rule explanation"
echo "  exit 2: the scheme+port form matches nothing, as documented"

echo "step 7: connection fault against HTTP/2 pairs is refused with exit 5"
rc=0
"$chaos_script" --in "$recording" --scenario connection --connection reset \
  --target '/v1/projects' --work-dir "$tmp/h2" >"$tmp/h2.out" 2>&1 || rc=$?
[[ "$rc" -eq 5 ]] || { cat "$tmp/h2.out" >&2; die "expected exit 5, got $rc"; }
grep -q 'SILENTLY IGNORED' "$tmp/h2.out" || die "exit 5 without the HTTP/2 explanation"
grep -q 'http1.1' "$tmp/h2.out" || die "exit 5 without the h1 workaround"
rc=0
"$chaos_script" --in "$recording" --scenario connection --connection reset \
  --target '/v1/projects' --allow-http2-connection-fault \
  --work-dir "$tmp/h2-override" >"$tmp/h2-override.out" 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || { cat "$tmp/h2-override.out" >&2; die "override should exit 0, got $rc"; }
grep -q 'WARNING: connection= faults are SILENTLY IGNORED' "$tmp/h2-override.out" \
  || die "override did not warn"
echo "  exit 5 by default, loud WARNING with --allow-http2-connection-fault"

# the recording is served as is: nothing in this proof may have touched it
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse >/dev/null 2>&1; then
  dirty="$(git -C "$repo_root" status --porcelain -- lab/proxymock/recording)"
  [[ -z "$dirty" ]] || die "source recording was modified: $dirty"
fi
echo "  source recording untouched"

echo "PASS: native faults observed (status, header, exact ratio, latency, chaos header), restore clean, exits 2 and 5 proven"
