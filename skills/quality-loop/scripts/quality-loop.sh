#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  quality-loop.sh <route> [args...]
  quality-loop.sh doctor [--root DIR]

Routes an intent to the matching validated skill script; args after the
route pass through unchanged (so `quality-loop.sh regression --help` prints
the regression script's own usage).

Routes:
  regression   proxymock-regression-test   did my change break anything / CI gate
  verify-fix   proxymock-verify-fix        incident: reproduce, then prove the fix
  perf         proxymock-perf-container    what can this service sustain / budget
  chaos        proxymock-chaos-mock        downstream misbehaves / resilience
  compare      proxymock-compare-results   before/after result comparison
  summarize    proxymock-summarize-recording   what is in this recording
  tune         proxymock-replay-tuning     mock misses / match-rate tuning
  load         proxymock-load-test         plain load numbers / SLO gates

doctor checks preconditions and prints an environment report:
  proxymock present + version, RRPair recording dirs under --root (default
  cwd) with pair counts, blueprint staging per recording parent, runtime
  proxy-support notes (Node needs >= 22.21 or 24 for NODE_USE_ENV_PROXY),
  and default port status (8080 app, 4140 proxy-out).

Exit codes:
  dispatch: the sibling script's own codes
  doctor:   0 healthy, 1 missing preconditions (listed), 2 usage
  2 for an unknown route or a missing sibling script
USAGE
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_root="$(cd "$script_dir/../.." && pwd)"

route_script() {
  case "$1" in
    regression) echo "$skills_root/proxymock-regression-test/scripts/proxymock-regression-test.sh" ;;
    verify-fix) echo "$skills_root/proxymock-verify-fix/scripts/proxymock-verify-fix.sh" ;;
    perf)       echo "$skills_root/proxymock-perf-container/scripts/proxymock-perf-container.sh" ;;
    chaos)      echo "$skills_root/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh" ;;
    compare)    echo "$skills_root/proxymock-compare-results/scripts/proxymock-compare-results.sh" ;;
    summarize)  echo "$skills_root/proxymock-summarize-recording/scripts/proxymock-summarize-recording.sh" ;;
    tune)       echo "$skills_root/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh" ;;
    load)       echo "$skills_root/proxymock-load-test/scripts/proxymock-load-test.sh" ;;
    *) return 1 ;;
  esac
}

cmd_doctor() {
  local root="$PWD"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        [[ $# -ge 2 ]] || { echo "error: --root needs a value" >&2; exit 2; }
        root="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "error: unknown doctor option: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
  [[ -d "$root" ]] || { echo "error: no such directory: $root" >&2; exit 2; }
  root="$(cd "$root" && pwd)"

  local missing=() warns=()
  echo "quality-loop doctor"
  echo "root: $root"
  echo

  # proxymock CLI
  if command -v proxymock >/dev/null 2>&1; then
    local pv
    pv="$(proxymock version 2>/dev/null | head -1 || true)"
    echo "ok   proxymock: $(command -v proxymock) (${pv:-version unknown})"
  else
    echo "MISS proxymock: not on PATH"
    missing+=("proxymock CLI not on PATH; install per https://docs.speedscale.com/proxymock/")
  fi

  # recording dirs: RRPair files live at <recording>/<host>/<timestamp>Z.md,
  # so strip two path levels off each hit and dedup
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

  # blueprint staging: blueprints load ONLY from the recording's parent
  # directory's blueprints/ subdir (the --in anchoring rule)
  local parents=() p seen bp found_bp
  for d in "${rec_dirs[@]+"${rec_dirs[@]}"}"; do
    p="$(dirname "$d")"
    seen=0
    for q in "${parents[@]+"${parents[@]}"}"; do [[ "$q" == "$p" ]] && seen=1; done
    [[ $seen -eq 1 ]] && continue
    parents+=("$p")
    found_bp=0
    for bp in "$p"/blueprints/*.json; do
      [[ -f "$bp" ]] || continue
      found_bp=1
      echo "ok   blueprint: $bp"
    done
    if [[ $found_bp -eq 0 ]]; then
      warns+=("no blueprints staged at $p/blueprints/ (needed only if the app has moving IDs like rotating tokens or order ids)")
    fi
  done

  # runtime proxy support: Node fetch ignores proxy env vars before
  # NODE_USE_ENV_PROXY landed in 24 (backported to 22.21)
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
  local w
  for w in "${warns[@]+"${warns[@]}"}"; do
    echo "WARN $w"
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "MISSING:"
    local m
    for m in "${missing[@]}"; do
      echo " - $m"
    done
    exit 1
  fi
  echo "healthy: dispatch a route with quality-loop.sh <route> [args...]"
  exit 0
}

main() {
  if [[ $# -lt 1 ]]; then
    usage >&2
    exit 2
  fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
  local route="$1"
  shift
  if [[ "$route" == "doctor" ]]; then
    cmd_doctor "$@"
  fi
  local target
  if ! target="$(route_script "$route")"; then
    echo "error: unknown route: $route" >&2
    usage >&2
    exit 2
  fi
  if [[ ! -f "$target" ]]; then
    echo "error: sibling skill script missing: $target" >&2
    echo "copy the sibling skills alongside this one; routes resolve relative to this script" >&2
    exit 2
  fi
  exec bash "$target" "$@"
}

main "$@"
