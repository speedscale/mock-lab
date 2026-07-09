#!/usr/bin/env bash
# Paced, on-camera walkthrough of the proxymock replay-tuning story.
#
# Recording layout:
#   Left pane : this script (banners narrate each beat).
#   Right pane: proxymock web at http://localhost:7788 (traffic lands live).
#
# Arc: record real app+downstream traffic -> break the mock set -> measure the
# MISSes -> tune -> measure the HITs. Same mechanics the proof script verifies,
# paced and captioned for a screen recording.
#
# Why a local downstream: the tune script replays recorded requests with a plain
# HTTP client that does not trust proxymock's MITM CA, so replaying HTTPS pairs
# fails the TLS handshake. Like the proof, we point the app at a LOCAL HTTP copy
# of the CNCF API (via --map) so the outbound pairs are replayable offline.
#
# Env knobs:
#   BEAT=2      seconds to hold on each narration banner
#   DELAY=1.5   seconds between driven calls (run_tests.sh owns DELAY; this
#               script paces itself with BEAT to avoid colliding)
set -euo pipefail

BEAT="${BEAT:-2}"
DELAY="${DELAY:-1.5}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$repo_root"

work="$repo_root/replay-work"
recording="$work/recording"
stale_mock="$work/stale-mock"
tune="$repo_root/skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh"

# Dynamic ports: this machine already has services on 8080/4143, so binding
# fixed ports collides. pick_port grabs free ones, same as the proof.
pick_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
DOWNSTREAM_PORT="$(pick_port)"   # local HTTP CNCF API (lab/server)
MAP_PORT="$(pick_port)"          # app dials this; proxymock maps it to the downstream
APP_PORT="$(pick_port)"          # the demo app
PROXY_IN_PORT="$(pick_port)"     # inbound proxy we drive traffic at
PROXY_OUT_PORT="$(pick_port)"
REC_HEALTH_PORT="$(pick_port)"

c_hdr='\033[1;36m'; c_say='\033[0;37m'; c_hit='\033[1;32m'; c_miss='\033[1;31m'; c_off='\033[0m'
banner() { printf "\n${c_hdr}== %s ==${c_off}\n" "$*"; }
say()    { printf "${c_say}%s${c_off}\n" "$*"; }
hold()   { sleep "$BEAT"; }
beat()   { banner "$1"; shift; [[ $# -gt 0 ]] && say "$*"; hold; }
show_rate() { # $1 = summary.json, $2 = color
  printf "%b" "$2"
  python3 - "$1" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"  hitRate={s['hitRate']}%  hits={s['hits']}  MISS={s['misses']}  passthrough={s['passthroughs']}  observed={s['observedMockRequests']}")
PY
  printf "%b" "$c_off"
}
is_out() { grep -qE '"direction": *"OUT"|direction: OUT' "$1"; }

command -v proxymock >/dev/null 2>&1 || { echo "proxymock not on PATH; install + 'proxymock init' first" >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "go not on PATH (needed for the demo app + downstream)" >&2; exit 1; }
[[ -x "$tune" ]] || { echo "tuning script missing: $tune" >&2; exit 1; }

mkdir -p "$work"
rm -rf "$recording" "$stale_mock" "$work/before" "$work/after"

web_pid=""; down_pid=""; rec_pid=""; app_runner=""
cleanup() {
  for p in "$rec_pid" "$down_pid" "$web_pid"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  # 'go run' leaves a compiled child behind when its parent is killed; reap by path.
  [[ -n "$app_runner" ]] && pkill -f "$app_runner" 2>/dev/null || true
  pkill -f "$repo_root/lab/server" 2>/dev/null || true
}
trap cleanup EXIT

wait_url() { # url, tries
  for _ in $(seq 1 "${2:-60}"); do curl -fsS "$1" >/dev/null 2>&1 && return 0; sleep 0.5; done
  return 1
}

# ---------------------------------------------------------------------------
beat "proxymock replay tuning" \
  "The Go demo app calls a CNCF projects API downstream. We'll record that" \
  "traffic, break the mock set, watch replay expose the gap, then tune it shut."

banner "opening proxymock web -> http://localhost:7788"
say "Bring the browser up on the right; new RRPairs appear here as they're captured."
proxymock web >"$work/web.log" 2>&1 &
web_pid="$!"
hold

# ---------------------------------------------------------------------------
banner "starting a local copy of the CNCF API (lab/server on :$DOWNSTREAM_PORT)"
( cd "$repo_root/lab/server" && PORT="$DOWNSTREAM_PORT" exec go run . ) >"$work/downstream.log" 2>&1 &
down_pid="$!"
wait_url "http://127.0.0.1:${DOWNSTREAM_PORT}/healthz" || { echo "downstream did not start; see $work/downstream.log" >&2; exit 1; }
say "up. The app will reach it through proxymock so every call is captured."
hold

# ---------------------------------------------------------------------------
beat "1/5  record" \
  "proxymock record --out replay-work/recording -- go run ." \
  "proxymock runs the app on :$APP_PORT, proxies in (:$PROXY_IN_PORT) and out, captures both."
# go/ has its own module, so the app must launch with cwd there (a bare
# 'go run <abspath>' resolves modules from the wrong dir). Wrap it.
app_runner="$work/run-go-app.sh"
printf '#!/usr/bin/env bash\ncd %q\nexec go run .\n' "$repo_root/go" >"$app_runner"
chmod +x "$app_runner"
PORT="$APP_PORT" DOWNSTREAM_URL="http://127.0.0.1:${MAP_PORT}" \
  proxymock record \
    --out "$recording" \
    --app-port "$APP_PORT" \
    --proxy-in-port "$PROXY_IN_PORT" \
    --proxy-out-port "$PROXY_OUT_PORT" \
    --health-port "$REC_HEALTH_PORT" \
    --map "${MAP_PORT}=http://127.0.0.1:${DOWNSTREAM_PORT}" \
    --app-health-endpoint "http://127.0.0.1:${APP_PORT}/" \
    -- "$app_runner" >"$work/record.log" 2>&1 &
rec_pid="$!"
wait_url "http://127.0.0.1:${PROXY_IN_PORT}/" || { echo "app/record did not start; see $work/record.log" >&2; exit 1; }

beat "1/5  drive the demo traffic" \
  "./lab/tests/run_tests.sh   (5 read endpoints + OAuth + order flow)" \
  "Watch each call land in proxymock web. DELAY=$DELAY paces them for the camera."
# Drive the inbound proxy via PORT (not --recording, which hardcodes 4143).
DELAY="$DELAY" PORT="$PROXY_IN_PORT" ./lab/tests/run_tests.sh || true
hold
kill "$rec_pid" 2>/dev/null || true; wait "$rec_pid" 2>/dev/null || true; rec_pid=""

# ---------------------------------------------------------------------------
# One recording, two roles, split by the RRPair 'direction' field (NOT host --
# with --map the downstream is also on loopback, so folder names don't separate
# them). Build an OUT-only replay dir so the tuner never fires the inbound pairs.
replay_out="$work/replay-out"; rm -rf "$replay_out"; mkdir -p "$replay_out"
in_n=0; out_n=0
while IFS= read -r f; do
  if is_out "$f"; then
    rel="${f#"$recording"/}"; mkdir -p "$replay_out/$(dirname "$rel")"; cp "$f" "$replay_out/$rel"
    out_n=$((out_n+1))
  else
    in_n=$((in_n+1))
  fi
done < <(find "$recording" -type f \( -name '*.md' -o -name '*.json' \))
[[ "$out_n" -gt 0 ]] || { echo "no OUT pairs captured; see $work/record.log" >&2; exit 1; }
beat "2/5  what got recorded" \
  "IN  = $in_n inbound pairs  -> route coverage (not replayed)" \
  "OUT = $out_n downstream pairs -> the mock + replay set the tuner uses"
say "Tuning replays the OUT pairs against the mock and counts HIT / MISS."
hold

# ---------------------------------------------------------------------------
beat "3/5  break the mock set" \
  "Delete the /v1/project/{id} and /v1/categories downstream recordings," \
  "simulating a stale mock set missing dependencies."
cp -R "$recording" "$stale_mock"
removed=0
while IFS= read -r f; do
  if grep -qE '/v1/project/|/v1/categories' "$f"; then rm -f "$f"; removed=$((removed+1)); fi
done < <(find "$stale_mock" -type f \( -name '*.md' -o -name '*.json' \))
say "removed $removed downstream recordings from the stale set"
hold

# replay-in is the OUT-only dir: the current tune script replays every file it
# is handed, so aiming it at the full recording would also fire the IN pairs at
# a proxy with no app behind them. (The proposed --in refactor drops IN pairs by
# direction, removing this manual split.)
# ---------------------------------------------------------------------------
beat "4/5  measure the stale mock -> MISSES" \
  "tune ... --mock-in stale-mock --replay-in <OUT>"
"$tune" --mock-in "$stale_mock" --replay-in "$replay_out" --work-dir "$work/before" >/dev/null 2>&1 || true
show_rate "$work/before/summary.json" "$c_miss"
say "miss files listed under .missFiles in $work/before/summary.json"
hold

# ---------------------------------------------------------------------------
beat "5/5  tune it back -> HITS" \
  "Restore the full recording as the mock set and replay the same traffic."
"$tune" --mock-in "$recording" --replay-in "$replay_out" --work-dir "$work/after" --fail-under 95 >/dev/null 2>&1
show_rate "$work/after/summary.json" "$c_hit"
hold

beat "done" \
  "Same replay, two mock sets: stale MISSes -> tuned HITs, --fail-under 95 passes." \
  "Artifacts in replay-work/ ; proxymock web still up at http://localhost:7788."
say "Ctrl-C when you've finished the recording."
wait "$web_pid" 2>/dev/null || true
