#!/usr/bin/env bash
# Proves: native --fault injection serves the documented behavior straight off
# the UNMODIFIED committed recording - status faults, a Retry-After header, an
# exact deterministic rate=F/N ratio, per-endpoint latency, the chaos response
# header, and a fault-free downstream after --restore; that connection faults
# fire on that recording, which is HTTP/2, with reset breaking the target and
# drop truncating its body against a same-port fault-free control; and that a
# --target matching nothing exits 2 instead of serving a silent no-op.
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

proxy_fetch() {
  # proxy_fetch PATH OUTFILE -> "CURL_RC HTTP_CODE BYTES". Connection faults
  # fail at the transport, where a status code alone says nothing.
  local p="$1" out="$2" code="" rc=0
  : >"$out"
  code="$(curl -s -m 10 -o "$out" -w '%{http_code}' \
    -x "http://127.0.0.1:$port" "${downstream}$p")" || rc=$?
  echo "$rc ${code:-000} $(wc -c <"$out" | tr -d ' ')"
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

echo "step 7: connection=reset fires on the HTTP/2 recording, target-only"
# every response in the committed recording is HTTP/2, which used to make
# connection faults invisible; the control is the same mock on the same port
# after --restore
grep -q '^HTTP/2' "$recording/demo-api.trafficreplay.com/2026-06-25_18-56-36.852193Z.md" \
  || die "the committed recording is no longer HTTP/2; this step proves nothing"
serve_chaos reset --scenario connection --connection reset --target '/v1/projects'
read -r f_rc f_code _ < <(proxy_fetch /v1/projects "$tmp/reset-target.body")
[[ "$f_rc" -ne 0 && "$f_code" == "000" ]] \
  || die "reset: target answered normally (curl rc $f_rc, status $f_code)"
read -r u_rc u_code u_bytes < <(proxy_fetch /v1/categories "$tmp/reset-other.body")
[[ "$u_rc" -eq 0 && "$u_code" == "200" ]] \
  || die "reset: untargeted endpoint broke too (curl rc $u_rc, status $u_code)"
"$chaos_script" --restore --work-dir "$tmp/reset" >"$tmp/reset-restore.out" 2>&1 || {
  cat "$tmp/reset-restore.out" >&2
  die "reset: --restore failed"
}
read -r c_rc c_code c_bytes < <(proxy_fetch /v1/projects "$tmp/control.body")
read -r _ _ c_other < <(proxy_fetch /v1/categories "$tmp/control-other.body")
[[ "$c_rc" -eq 0 && "$c_code" == "200" && "$c_bytes" -gt 0 ]] \
  || die "reset: control run did not serve the target (curl rc $c_rc, status $c_code)"
[[ "$u_bytes" -eq "$c_other" ]] \
  || die "reset: untargeted body changed under the fault ($u_bytes vs $c_other bytes)"
echo "  target broken at the transport (curl rc $f_rc), untargeted intact at $u_bytes bytes,"
echo "  same port fault-free after restore: $c_bytes bytes"
ql_sweep_port "$port"

echo "step 8: connection=drop returns 200 with a silently truncated body"
serve_chaos drop --scenario connection --connection drop --target '/v1/projects'
read -r d_rc d_code d_bytes < <(proxy_fetch /v1/projects "$tmp/drop-target.body")
[[ "$d_code" == "200" ]] || die "drop: expected a 200 status, got $d_code"
[[ "$d_bytes" -lt "$c_bytes" ]] \
  || die "drop: body was not truncated ($d_bytes of $c_bytes control bytes)"
read -r _ o_code o_bytes < <(proxy_fetch /v1/categories "$tmp/drop-other.body")
[[ "$o_code" == "200" && "$o_bytes" -eq "$c_other" ]] \
  || die "drop: untargeted endpoint was not intact ($o_code, $o_bytes bytes)"
echo "  200 with $d_bytes of $c_bytes bytes (curl rc $d_rc): status alone would pass"
ql_sweep_port "$port"

# the recording is served as is: nothing in this proof may have touched it
if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse >/dev/null 2>&1; then
  dirty="$(git -C "$repo_root" status --porcelain -- lab/proxymock/recording)"
  [[ -z "$dirty" ]] || die "source recording was modified: $dirty"
fi
echo "  source recording untouched"

echo "PASS: native faults observed (status, header, exact ratio, latency, chaos header),"
echo "PASS: connection faults fire on the HTTP/2 recording (reset breaks the target, drop"
echo "PASS: truncates it) with untargeted traffic intact, restore clean, exit 2 proven"
