#!/usr/bin/env bash
# Shows the quality loop catching four real defects in this repo's Go app with
# the native proxymock commands the pack documents. This is a demo, not a test:
# it prints findings and cleans up, it asserts nothing. prove-quality-loop.sh
# owns the exit-code contract. Every bug is seeded in a TEMP COPY of go/, so
# tracked source is never touched.
#
#   ./demo.sh [regression|contract|chaos|verify-fix]   (default: all four)
#   PAUSE=1 ./demo.sh                                  waits for Enter between
#                                                      scenes, for screencasts
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
rec="$root/lab/proxymock/recording"
spec="$root/lab/openapi.yaml"
# localhost, never 127.0.0.1: the committed blueprint filters network_address
# CONTAINS "localhost", and the other spelling loads it but fires zero chains,
# so the auth endpoints silently 401 and the demo looks broken.
app="http://localhost:8080"
tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}/quality-loop-demo.$$"
src="$tmp/app"
mock_pid=""
rc=0

fail()  { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
say()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
note()  { printf '   %s\n' "$*"; }
busy()  { lsof -nP -iTCP:8080 -iTCP:4140 -sTCP:LISTEN >/dev/null 2>&1; }
probe() { curl -s -m 10 -o /dev/null -w '%{http_code}, %{size_download} bytes' "$app$1"; }
pause() { [[ "${PAUSE:-0}" == 1 ]] && { printf '\n-- Enter for the next scene --'; read -r _; }; return 0; }
run()   { printf '\n$ %s\n' "$*"; "$@" >"$tmp/out" 2>&1; rc=$?; printf '   exit %d\n' "$rc"; }
show()  { grep -hE "$1" "$tmp/out" | sed 's/^/   /'; }

# build clean|stats|categories: restore the temp copy's main.go, seed, rebuild
build() {
  cp "$root/go/main.go" "$src/main.go"
  case "$1" in
    stats)
      perl -pi -e 's/"total":       len\(projects\),/"total":       len(projects) - 1,/' "$src/main.go" ;;
    categories)
      perl -0pi -e 's|fetch\(w, "/v1/categories"\)|resp, err := http.Get(downstream + "/v1/categories")
		if err != nil { http.Error(w, "downstream unreachable", 502); return }
		defer resp.Body.Close()
		var env struct{ Categories []map[string]any }
		if json.NewDecoder(resp.Body).Decode(&env) != nil { http.Error(w, "categories envelope decode failed", 500); return }
		writeJSON(w, 200, env)|' "$src/main.go" ;;
  esac
  (cd "$src" && go build -o app .) || fail "go build failed in $src"
}

# start [mock flags...]: the app on :8080 with its downstream mocked
start() {
  busy && fail "port 8080 or 4140 is busy -- free it before running the demo"
  proxymock mock --in "$rec" --no-out "$@" -- "$src/app" >"$tmp/app.log" 2>&1 &
  mock_pid=$!
  for _ in $(seq 1 60); do curl -fsS -o /dev/null -m 2 "$app/" 2>/dev/null && break; sleep 0.5; done
  grep -q "Starting HTTP server on :8080" "$tmp/app.log" \
    || { cat "$tmp/app.log" >&2; fail "app never started"; }
}

stop() {
  [[ -n "$mock_pid" ]] && { kill "$mock_pid" 2>/dev/null; wait "$mock_pid" 2>/dev/null; }
  mock_pid=""
  for _ in $(seq 1 40); do busy || return 0; sleep 0.25; done
  fail "8080/4140 still listening after SIGTERM"
}

cleanup() {
  [[ -n "$mock_pid" ]] && kill "$mock_pid" 2>/dev/null
  rm -rf "$tmp"
}

regression() {
  say "SCENE 1 -- regression: the defect a status-code gate ships to production"
  note "seeding an off-by-one in statsHandler: \"total\": len(projects) - 1"
  build clean; start
  run proxymock replay --in "$rec" --test-against "$app" --out "$tmp/baseline"
  note "baseline replay of the clean build: the noise floor to gate against"
  stop
  build stats; start
  note "GET /api/stats now answers $(curl -s "$app/api/stats" | tr -d ' \n')"
  run proxymock replay --in "$rec" --test-against "$app" --out "$tmp/reg" \
    --baseline "$tmp/baseline" --fail-on-new-mismatch
  show 'NEW MISMATCH'
  show 'TOTAL .*ms'
  note "exit 3. Status stayed 200 and FAILED stayed 0% -- nothing in the"
  note "transport metrics moved, so a status-only gate would have shipped it."
  stop
}

contract() {
  say "SCENE 2 -- contract: does the downstream still match its OpenAPI spec?"
  note "the 5 committed RRPairs from demo-api.trafficreplay.com vs lab/openapi.yaml"
  run proxymock validate --spec "$spec" --in "$rec/demo-api.trafficreplay.com"
  show 'checked .* pair'
  rm -rf "$tmp/badpairs"
  cp -R "$rec/demo-api.trafficreplay.com" "$tmp/badpairs"
  perl -0pi -e 's/"count":\s*(\d+)/"count": "$1"/' \
    "$(grep -rl '"count"' "$tmp/badpairs" | head -1)"
  note "now seeding one violation: a categories count integer shipped as a string"
  run proxymock validate --spec "$spec" --in "$tmp/badpairs"
  show 'VIOLATION|type mismatch|checked .* pair'
  note "exit 2, with the JSON path of the offending field. No app, no replay --"
  note "this is the recording alone, checked against the spec."
  rm -rf "$tmp/badpairs"
}

chaos() {
  say "SCENE 3 -- chaos: what a lying downstream does to a healthy-looking app"
  build clean; start
  note "control, downstream behaving: GET /api/projects -> $(probe /api/projects)"
  stop
  start --fault '/v1/projects:connection=drop'
  note "--fault '/v1/projects:connection=drop': GET /api/projects -> $(probe /api/projects)"
  note "Still HTTP 200, and the project list is gone -- the app served whatever"
  note "it managed to read before the drop. Status assertions all pass on that."
  stop
  start --fault '/v1/projects:status=503'
  note "--fault '/v1/projects:status=503': GET /api/projects -> $(probe /api/projects)"
  note "but GET /api/stats -> $(curl -s "$app/api/stats" | tr -d ' \n')"
  note "200 with correct-looking aggregates while the downstream is 503ing."
  note "app log lines this whole run: $(grep -cE '^[0-9]{4}/[0-9]{2}/[0-9]{2}' "$tmp/app.log") -- the startup banner."
  note "Nothing in your telemetry is going to page anyone about this."
  stop
}

verify_fix() {
  say "SCENE 4 -- verify-fix: reproduce the incident, then prove the fix"
  note "bug: GET /api/categories decodes a bare JSON array into a {categories:[]} wrapper"
  rm -rf "$tmp/incident-src" "$tmp/incident"
  mkdir -p "$tmp/incident-src/localhost"
  cp "$(grep -rl 'api/categories' "$rec/localhost" | head -1)" "$tmp/incident-src/localhost/"
  build categories; start
  note "GET /api/categories -> $(probe /api/categories)"
  run proxymock replay --in "$tmp/incident-src" --test-against "$app" --out "$tmp/incident"
  note "incident captured from the broken build: $(grep -hm1 '^HTTP/' "$tmp/incident"/localhost/*.md)"
  run proxymock replay --in "$tmp/incident" --test-against "$app" --out "$tmp/vf-bug" \
    --verify-fix --expect '^/api/categories'
  show 'BUG REPRODUCED'
  note "exit 2. An all-match run is the FAILURE here: match compares observed"
  note "against recorded, and the recording IS the 500."
  stop
  build clean; start
  run proxymock replay --in "$tmp/incident" --test-against "$app" --out "$tmp/vf-fix" \
    --verify-fix --expect '^/api/categories'
  show 'FIX CONFIRMED'
  note "exit 0. Same capture, same command, opposite verdict -- and the other"
  note "pairs are still scored, so a fix that broke a neighbour would say COLLATERAL."
  stop
}

for c in proxymock go curl lsof perl; do
  command -v "$c" >/dev/null 2>&1 || fail "missing required command: $c"
done
[[ -d "$rec" ]] || fail "missing committed recording: $rec"
trap cleanup EXIT
mkdir -p "$tmp"
cp -R "$root/go" "$src"
rm -rf "$src/proxymock" "$src/proxymock.log"
cd "$tmp" || fail "cannot enter $tmp"   # proxymock writes proxymock.log into cwd

case "${1:-all}" in
  regression) regression ;;
  contract)   contract ;;
  chaos)      chaos ;;
  verify-fix) verify_fix ;;
  all)        regression; pause; contract; pause; chaos; pause; verify_fix ;;
  *) printf 'usage: demo.sh [regression|contract|chaos|verify-fix]\n' >&2; exit 2 ;;
esac

say "Done -- every verdict above came out of proxymock, and 8080/4140 are free."
