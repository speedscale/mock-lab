#!/usr/bin/env bash
# Optional convenience over the native proxymock commands. Each mode builds one
# command, prints it, and execs it, so the output and the exit code you see are
# proxymock's own. Nothing here re-derives a verdict or writes a summary file:
# proxymock writes <out>/replay-verdict.json and that is the contract.
set -euo pipefail

PM="${PROXYMOCK:-proxymock}"
MIN_PROXYMOCK="2.5.814"

usage() {
  cat <<'USAGE'
Usage: quality-loop.sh <mode> [args...]

Native modes (build and exec one proxymock command; its exit code is yours):
  regression  --in DIR --test-against URL [--baseline DIR]
              -> proxymock replay [--baseline DIR --fail-on-new-mismatch]
              exits: 0 pass, 3 new mismatch
  verify-fix  --in DIR --test-against URL [--expect RE] [--baseline DIR]
              -> proxymock replay --verify-fix
              exits: 0 fix confirmed, 2 bug still reproduces, 3 collateral
  contract    --spec FILE --in DIR
              -> proxymock validate
              exits: 0 conformant, 2 violations, 3 no spec route
  chaos       --in DIR --fault 'PAT:action=value[,...]' [-- APP CMD...]
              -> proxymock mock (runs until stopped)
  load        --in DIR --test-against URL [--vus N] [--for D] [--no-load-test]
              -> proxymock replay --vus --for --load-test
              exits: 0, or 1 when a --fail-if threshold trips

Any flag this script does not name is forwarded to proxymock unchanged.

Routes to this repo's analysis skills (args pass through to their scripts):
  compare | summarize | tune | load-test

  doctor [--root DIR]   preconditions and environment report
              exits: 0 healthy, 1 missing preconditions, 2 usage

PROXYMOCK=/path/to/proxymock overrides the binary. Unknown mode: exit 2.
USAGE
}

die() { echo "error: $2" >&2; exit "$1"; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_root="$(cd "$script_dir/../.." && pwd)"

run() {
  # print the native command, then become it: no wrapper in the exit path
  echo "+ $*" >&2
  exec "$@"
}

# --- native modes -------------------------------------------------------------

mode_regression() {
  local in="" target="" baseline="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in="$2"; shift 2 ;;
      --test-against) target="$2"; shift 2 ;;
      --baseline) baseline="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [[ -n "$in" && -n "$target" ]] || die 2 "regression needs --in and --test-against"
  local cmd=("$PM" replay --in "$in" --test-against "$target")
  # replay rejects --fail-on-new-mismatch without a baseline, so the gate only
  # goes on once there is something to be relative to
  [[ -n "$baseline" ]] && cmd+=(--baseline "$baseline" --fail-on-new-mismatch)
  run "${cmd[@]}" ${rest[@]+"${rest[@]}"}
}

mode_verify_fix() {
  local in="" target="" expect="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in="$2"; shift 2 ;;
      --test-against) target="$2"; shift 2 ;;
      --expect) expect="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [[ -n "$in" && -n "$target" ]] || die 2 "verify-fix needs --in and --test-against"
  local cmd=("$PM" replay --in "$in" --test-against "$target" --verify-fix)
  [[ -n "$expect" ]] && cmd+=(--expect "$expect")
  run "${cmd[@]}" ${rest[@]+"${rest[@]}"}
}

mode_contract() {
  local spec="" in="" rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec) spec="$2"; shift 2 ;;
      --in) in="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [[ -n "$spec" && -n "$in" ]] || die 2 "contract needs --spec and --in"
  run "$PM" validate --spec "$spec" --in "$in" ${rest[@]+"${rest[@]}"}
}

mode_chaos() {
  # `mock --in` is mandatory: it does not discover a recording from cwd.
  # Everything after a bare -- is the app command and must stay last.
  local ins=() faults=() rest=() app=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) ins+=(--in "$2"); shift 2 ;;
      --fault) faults+=(--fault "$2"); shift 2 ;;
      --) shift; app=("$@"); break ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [[ ${#ins[@]} -gt 0 ]] || die 2 "chaos needs at least one --in (mock does not discover a recording from cwd)"
  [[ ${#faults[@]} -gt 0 ]] || die 2 "chaos needs at least one --fault 'PATTERN:action=value'"
  local cmd=("$PM" mock "${ins[@]}" "${faults[@]}")
  cmd+=(${rest[@]+"${rest[@]}"})
  [[ ${#app[@]} -gt 0 ]] && cmd+=(-- "${app[@]}")
  run "${cmd[@]}"
}

mode_load() {
  local in="" target="" vus="" dur="" load_test=1 rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --in) in="$2"; shift 2 ;;
      --test-against) target="$2"; shift 2 ;;
      --vus) vus="$2"; shift 2 ;;
      --for) dur="$2"; shift 2 ;;
      --no-load-test) load_test=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  [[ -n "$in" && -n "$target" ]] || die 2 "load needs --in and --test-against"
  local cmd=("$PM" replay --in "$in" --test-against "$target")
  [[ -n "$vus" ]] && cmd+=(--vus "$vus")
  [[ -n "$dur" ]] && cmd+=(--for "$dur")
  # --load-test drops match scoring, which is the honest default for a load run;
  # --no-load-test puts requests.result-match-pct back
  [[ "$load_test" -eq 1 ]] && cmd+=(--load-test)
  run "${cmd[@]}" ${rest[@]+"${rest[@]}"}
}

# --- routes to this repo's own analysis skills --------------------------------

route_script() {
  case "$1" in
    compare)   echo "$skills_root/proxymock-compare-results/scripts/proxymock-compare-results.sh" ;;
    summarize) echo "$skills_root/proxymock-summarize-recording/scripts/proxymock-summarize-recording.sh" ;;
    tune)      echo "$skills_root/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh" ;;
    load-test) echo "$skills_root/proxymock-load-test/scripts/proxymock-load-test.sh" ;;
    *) return 1 ;;
  esac
}

# --- doctor -------------------------------------------------------------------

cmd_doctor() {
  local root="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        [[ $# -ge 2 ]] || die 2 "--root needs a value"
        root="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die 2 "unknown doctor option: $1" ;;
    esac
  done
  [[ -d "$root" ]] || die 2 "no such directory: $root"
  root="$(cd "$root" && pwd)"

  local missing=() warns=()
  echo "quality-loop doctor"
  echo "root: $root"
  echo

  # Every behavior this pack documents was measured on MIN_PROXYMOCK; older
  # builds differ on the items named below, so flag a stale CLI without failing.
  local stale_note="connection faults, native body scoring, --require-blueprint, proxymock validate, and teardown differ on older builds"
  if command -v "$PM" >/dev/null 2>&1 || [[ -x "$PM" ]]; then
    local pv ver oldest
    pv="$("$PM" version 2>/dev/null | head -1 || true)"
    echo "ok   proxymock: $(command -v "$PM" || echo "$PM") (${pv:-version unknown})"
    ver="$(printf '%s\n' "$pv" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -z "$ver" ]]; then
      warns+=("proxymock version not parseable from '${pv:-}'; this pack assumes >= $MIN_PROXYMOCK ($stale_note)")
    else
      oldest="$(printf '%s\n%s\n' "$MIN_PROXYMOCK" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
      if [[ "$oldest" != "$MIN_PROXYMOCK" ]]; then
        warns+=("proxymock $ver is older than $MIN_PROXYMOCK, which this pack's guidance assumes: $stale_note")
      else
        echo "ok   proxymock version $ver: >= $MIN_PROXYMOCK (this pack's minimum)"
      fi
    fi
  else
    echo "MISS proxymock: not on PATH"
    missing+=("proxymock CLI not on PATH; install per https://docs.speedscale.com/proxymock/")
  fi

  # RRPair files live at <recording>/<host>/<timestamp>Z.md, so strip two path
  # levels off each hit and dedup
  local rec_dirs=() d
  while IFS= read -r d; do
    [[ -n "$d" ]] && rec_dirs+=("$d")
  done < <(
    find "$root" \( -name .git -o -name node_modules \) -prune -o \
      -type f -name '*Z.md' -print 2>/dev/null \
      | sed -e 's#/[^/]*/[^/]*$##' | sort -u
  )
  if [[ ${#rec_dirs[@]} -eq 0 ]]; then
    echo "MISS recordings: no RRPair recording dirs under $root"
    missing+=("no RRPair recording dirs found; enter the loop with: proxymock record -- <app cmd> (then drive real traffic)")
  else
    local pairs
    for d in "${rec_dirs[@]}"; do
      pairs="$(find "$d" -type f -name '*Z.md' 2>/dev/null | wc -l | tr -d ' ')"
      echo "ok   recording: $d ($pairs RRPairs)"
    done
  fi

  # Blueprints load from the workspace blueprints/ beside the recording AND from
  # one inside --in (replay reads --in recursively). Accept either; reporting a
  # staged blueprint as misplaced sends people to move a file that is working.
  # Sibling recordings share a workspace, so dedup both lines.
  local bp ws_dir found_bp seen_bp=() seen_ws=()
  for d in "${rec_dirs[@]+"${rec_dirs[@]}"}"; do
    ws_dir="$(dirname "$d")"
    found_bp=0
    for bp in "$ws_dir"/blueprints/*.json "$d"/blueprints/*.json; do
      [[ -f "$bp" ]] || continue
      found_bp=1
      case " ${seen_bp[*]+${seen_bp[*]}} " in *" $bp "*) continue ;; esac
      seen_bp+=("$bp")
      echo "ok   blueprint: $bp"
    done
    [[ $found_bp -eq 1 ]] && continue
    case " ${seen_ws[*]+${seen_ws[*]}} " in *" $ws_dir "*) continue ;; esac
    seen_ws+=("$ws_dir")
    warns+=("no blueprints staged at $ws_dir/blueprints/ or <recording>/blueprints/ (needed only if the app has moving IDs like rotating tokens or order ids)")
  done

  # Node fetch ignores proxy env vars before NODE_USE_ENV_PROXY landed in 24
  # (backported to 22.21)
  if command -v node >/dev/null 2>&1; then
    local nv major minor rest
    nv="$(node --version 2>/dev/null | sed 's/^v//')"
    major="${nv%%.*}"; rest="${nv#*.}"; minor="${rest%%.*}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
      if [[ "$major" -ge 24 || ( "$major" -eq 22 && "$minor" -ge 21 ) ]]; then
        echo "ok   node $nv: proxy-capable; set NODE_USE_ENV_PROXY=1 (and NODE_EXTRA_CA_CERTS) when recording Node apps"
      else
        warns+=("node $nv: fetch ignores proxy env vars; Node capture needs >= 22.21 or 24 with NODE_USE_ENV_PROXY=1")
      fi
    else
      warns+=("node version '$nv' not parseable; verify >= 22.21 or 24 before recording Node apps")
    fi
  else
    echo "info node: not present (only needed for Node apps)"
  fi

  # default ports: 8080 (lab app), 4140 (proxymock proxy-out)
  if command -v lsof >/dev/null 2>&1; then
    local port pid
    for port in 8080 4140; do
      pid="$(lsof -ti "tcp:${port}" 2>/dev/null | head -1 || true)"
      if [[ -n "$pid" ]]; then
        warns+=("port $port busy (pid $pid): fine if it is your app or an active mock, otherwise free it")
      else
        echo "ok   port $port: free"
      fi
    done
  else
    echo "info ports: lsof not present, skipping port check"
  fi

  echo
  local w m
  for w in "${warns[@]+"${warns[@]}"}"; do
    echo "WARN $w"
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "MISSING:"
    for m in "${missing[@]}"; do
      echo " - $m"
    done
    exit 1
  fi
  echo "healthy: run a mode with quality-loop.sh <mode> [args...]"
  exit 0
}

main() {
  [[ $# -ge 1 ]] || { usage >&2; exit 2; }
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
  local mode="$1"
  shift
  case "$mode" in
    doctor)     cmd_doctor "$@" ;;
    regression) mode_regression "$@" ;;
    verify-fix) mode_verify_fix "$@" ;;
    contract)   mode_contract "$@" ;;
    chaos)      mode_chaos "$@" ;;
    load)       mode_load "$@" ;;
  esac
  local target
  target="$(route_script "$mode")" || {
    echo "error: unknown mode: $mode" >&2
    usage >&2
    exit 2
  }
  [[ -f "$target" ]] || die 2 "skill script missing: $target (routes resolve relative to this script)"
  exec bash "$target" "$@"
}

main "$@"
