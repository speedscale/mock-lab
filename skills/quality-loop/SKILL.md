---
name: quality-loop
description: Route a development intent to the right validated proxymock skill (regression gate, incident fix verification, capacity budget, chaos resilience, contract conformance, comparison, summarization, match-rate tuning, load) and get a repo into the traffic quality loop with one recording. Includes a doctor that checks proxymock, recordings, blueprints, runtime proxy support, and ports. Use when users ask how to test a change with recorded traffic, which proxymock skill applies to a task, to set up the quality loop in a repo, or to check whether the environment is ready.
argument-hint: <doctor|regression|verify-fix|perf|chaos|contract|compare|summarize|tune|load> [args...]
---

# proxymock Quality Loop

The loop: capture real traffic once -> keep it as a snapshot (RRPair files)
-> run your code against the snapshot -> act on the diff. One snapshot feeds
every tier: the same recording is the regression gate's input, the mock's
source data, the load test's request script, and the chaos variant's raw
material. Nothing below asks for a second capture.

This skill is a router and a playbook, not a reimplementation. Every route
dispatches to a sibling skill that was validated on its own; read the routing
table, pick the row that matches the intent, then follow that skill's
SKILL.md for flags and interpretation. The script here only dispatches and
checks preconditions.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Routing

Match the developer's intent to a row. The route column is the dispatcher
argument; args after it pass through to the sibling script unchanged.

| Intent sounds like | Route | Skill |
| --- | --- | --- |
| "Did my change break anything?", pre-ship check, CI gate on recorded traffic | `regression` | **proxymock-regression-test** |
| "Prod incident: reproduce it and prove the fix" | `verify-fix` | **proxymock-verify-fix** |
| "What can this service sustain?", capacity planning, perf budget gate | `perf` | **proxymock-perf-container** |
| "How does it behave when the downstream misbehaves?", resilience, retry/timeout audit | `chaos` | **proxymock-chaos-mock** |
| "Does my dependency's behavior match its spec?", "can I mock from the spec before recording?" | `contract` | **proxymock-contract-test** |
| "What changed between these two runs?", before/after result comparison | `compare` | **proxymock-compare-results** |
| "What is in this recording?", describe captured traffic | `summarize` | **proxymock-summarize-recording** |
| "Replay misses the mock", match-rate tuning, signature/transform fixes | `tune` | **proxymock-replay-tuning** |
| "Just give me load numbers", one flat run with SLO gates | `load` | **proxymock-load-test** |

Route-specific notes an agent should apply while routing:

- **regression**: the gate is per-RRPair match tags and budget flips, never
  `requests.failed`. When field-level body changes matter, add the skill's
  MCP `response_diff` step; match tags tolerate body changes.
- **verify-fix**: run `--reproduce` against the buggy build FIRST, then
  verify the fixed build. The capture is the test; no hand-written test is
  needed. Pass/fail semantics invert: an all-match run means the bug still
  reproduces, and the fix appears as "recorded 500 -> observed 200".
- **perf**: the answer carries an honesty gate. On a shared host the load
  generator saturates before an efficient app does, so results are lower
  bounds and harness-bound levels are refused, not reported as app limits.
- **chaos**: six scenarios (down, ratelimit, garbage, slow, connection,
  flaky) built from native `mock --fault` flags, with ratios exact and
  deterministic via `rate=F/N`. What to look for in the app under test:
  status swallowing (200 while the downstream 503s), header stripping
  (`Retry-After` never reaches clients), garbage passthrough (downstream junk
  proxied as 200), no timeout budget (hangs on a slow downstream), no retry
  (client-visible failure rate equals the injected ratio), and truncated
  bodies accepted as 200 under `connection=drop`.

Tie-breakers between neighboring rows:

- **regression vs verify-fix** is decided by which recording you hold. A
  healthy recording plus "did I break it" is `regression`. An incident
  capture (recorded errors are the truth) plus "is it fixed" is
  `verify-fix`.
- **perf vs load**: `load` is one flat VU level with optional `--fail-if`
  gates; `perf` walks the ladder, finds the knee, gates budgets there, and
  attributes CPU. Plain numbers = `load`; capacity claims = `perf`.
- **compare / summarize / tune** are analysis routes. They read result or
  recording dirs and never drive traffic at your app by themselves
  (`compare` can still gate CI via its own `--fail-on-regression`).

## One-time setup (add water)

A repo enters the loop once; after this every route reads the same files.

1. **Record once.** From the app's own directory run
   `proxymock record -- <app command>`, then drive real traffic at it (the
   repo's test driver, a curl pass over every endpoint, a browser session).
   The resulting RRPair directory is the snapshot. In this repo:
   `cd go && proxymock record -- go run .` plus
   `./lab/tests/run_tests.sh --recording` from the root.
2. **Keep the recording.** Commit it as the baseline snapshot; RRPairs are
   markdown and diff cleanly. This repo ships one at
   `lab/proxymock/recording`.
3. **Create the comparison baseline.** Run the `regression` route once
   against a known-good build and keep its `replayed/` output dir. From then
   on gate baseline-relative (`--baseline`), so the deterministic noise
   floor does not false-positive.
4. **Stage blueprints if the app has moving IDs** (rotating tokens,
   generated order ids). Put the smart-replace blueprint JSON in the
   recording's parent proxymock directory under `blueprints/`, e.g.
   `lab/proxymock/blueprints/`. The anchoring rule is strict: blueprints
   load ONLY from the `--in` path's parent directory's `blueprints/` subdir,
   not from cwd and not from the output workspace. Without them, moving-ID
   endpoints 401/404 on every replay and regressions on those paths are
   undetectable.

`quality-loop.sh doctor` verifies all of this.

## Shared gotchas (apply on every route)

Validated facts the sibling skills document individually; collected here
because every flow eventually hits them.

- **Blueprint anchoring**: blueprints load only from the `--in` parent's
  `blueprints/` dir (see setup step 4).
- **"Applied N active blueprint(s)" lies**: the console line reflects
  snapshot-scoped state, not your workspace. Verify application by grepping
  the replay output RRPairs for `smart_replace` events.
- **`proxymock mock` needs an explicit `--in`**: it does not discover a
  recording from cwd.
- **Mock-source union**: `proxymock mock` accepts repeated `--in` flags and
  serves mocks from all of them; no combined temp dir is needed.
- **`requests.failed` hides status regressions**: a 201 that becomes a 200
  still completes the HTTP exchange, so `requests.failed` stays 0. The
  per-RRPair match tag is the datum.
- **Recorded-error-reproduced is a match PASS**: match compares observed
  against recorded, so faithfully replaying a captured 500 passes. This is
  why verify-fix inverts the semantics.
- **Deterministic noise floor**: `Date` response headers, rotating
  tokens/order ids, and their `Content-Length` side effects differ between
  any two runs. Allowlist them before judging diffs, and gate
  baseline-relative so they never count as regressions.
- **A malformed RRPair is skipped, silently**: the rest of the directory
  still serves, but the warning only appears at `-v -v`, so a bad edit
  degrades to a mysteriously missing endpoint rather than a loud failure.
- **Mock DATA hot-reloads, FLAGS do not**: `--mock-reload-interval 1s` picks
  up an RRPair edit in about a second, but `--fault` and the other mock
  flags are read once at startup, so changing the fault set means a restart.
  Restarting a mock that WRAPS the app restarts the app too; run recovery
  scenarios un-wrapped.
- **A fault regexp that matches nothing is a silent no-op**: the pattern is
  matched against the bare path and host+path only, with no scheme, port, or
  method, so a plausible full-URL pattern starts cleanly and does nothing.
- **`connection=` faults are silently ignored on HTTP/2**: no warning at any
  verbosity, the app gets a clean 200. The chaos skill refuses the
  combination rather than let it look like resilience.
- **Teardown is SIGTERM plus surviving children**: a wrapped app can
  outlive the proxymock process that launched it. After stopping a session,
  kill leftover listeners on your ports (scoped to your own ports).
- **Incident captures lack the fixed path's downstream traffic**: the buggy
  handler usually errored before calling its dependency, so the capture has
  no outbound pair for the fixed code path. Union the incident capture with
  a healthy recording via repeated `--in` when mocking the fixed build's
  downstream.

## Inputs

The dispatcher forwards everything after the route to the sibling script;
see that skill's SKILL.md for its flags.

- `<route> [args...]`: one of `regression`, `verify-fix`, `perf`, `chaos`,
  `contract`, `compare`, `summarize`, `tune`, `load`. Args pass through
  unchanged, so
  `quality-loop.sh regression --help` prints the regression script's own
  usage.
- `doctor [--root DIR]`: precondition check and environment report over
  `DIR` (default: cwd). Reports proxymock presence and version, RRPair
  recording directories found (with pair counts), blueprint staging for each
  recording's parent dir, runtime proxy-support notes (Node `fetch` ignores
  proxy env vars before 22.21/24; on supported versions set
  `NODE_USE_ENV_PROXY=1`), and whether the default app and proxy ports
  (8080, 4140) are free.

Run the bundled script:

```bash
# is this repo in the loop, and is the environment ready?
./skills/quality-loop/scripts/quality-loop.sh doctor

# route: pre-ship regression gate against a known-good baseline
./skills/quality-loop/scripts/quality-loop.sh regression \
  --in ./proxymock/recording --test-against http://localhost:8080 \
  --baseline ./regress-base/replayed --fail-on-regression

# route: prove a fix against an incident capture
./skills/quality-loop/scripts/quality-loop.sh verify-fix \
  --in ./incident/recording --test-against http://localhost:8080 --reproduce
```

If this skill has been copied outside `mock-lab`, replace
`./skills/quality-loop` with the copied skill directory and copy the sibling
skills alongside it: the dispatcher resolves them relative to its own
location (`../../<skill>/scripts/`). The prove script and the sibling skill
scripts also source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Output contract

- **Dispatch routes**: the dispatcher execs the sibling script, so stdout,
  files, and exit codes are the sibling's own contract, documented in its
  SKILL.md. The dispatcher adds nothing.
- **`doctor`**: prints the environment report to stdout. Exit `0` when
  healthy (proxymock present and at least one recording dir found; warnings
  such as missing blueprints, old Node, or busy ports do not fail the
  check). Exit `1` with a `MISSING:` list naming each unmet precondition.
  Exit `2` on usage errors.
- **Dispatcher errors**: an unknown route or a missing sibling script prints
  usage to stderr and exits `2`.

## Interpretation

- **doctor: MISSING proxymock**: install the CLI first; every route needs
  it.
- **doctor: MISSING recording dirs**: the repo is not in the loop yet. Run
  the one-time setup; nothing else in this pack works without a snapshot.
- **doctor: blueprint warning on a recording**: only a problem if that app
  has moving IDs. If it does, expect 401/404 noise on replay and an
  undetectable-regression blind spot on those endpoints until a blueprint is
  staged in the right `blueprints/` dir.
- **doctor: Node version warning**: recording a Node app on that runtime
  captures nothing through the proxy. Upgrade to >= 22.21 or 24 and set
  `NODE_USE_ENV_PROXY=1` (plus `NODE_EXTRA_CA_CERTS` for TLS).
- **doctor: busy port warning**: fine when it is your app or an active mock
  session; otherwise free the port before recording or replaying.
- **A route's own findings**: interpret with that skill's Interpretation
  section, not here; this skill guarantees only that you ran the right one.

## Related

- **proxymock-regression-test**: the `regression` route; match-tag and
  budget-flip gating over a healthy recording.
- **proxymock-verify-fix**: the `verify-fix` route; inverted semantics over
  an incident capture, reproduce-then-verify.
- **proxymock-perf-container**: the `perf` route; VU ladder, knee, budget
  gate, CPU-attribution honesty gate.
- **proxymock-chaos-mock**: the `chaos` route; native `mock --fault`
  injection with deterministic `rate=F/N` ratios.
- **proxymock-contract-test**: the `contract` route; spec-vs-traffic
  conformance and mock-from-spec.
- **proxymock-compare-results**: the `compare` route; deep report and drift
  comparison between two result sets.
- **proxymock-summarize-recording**: the `summarize` route; what a recording
  contains before you mock or replay it.
- **proxymock-replay-tuning**: the `tune` route; HIT/MISS/PASSTHROUGH
  measurement and mock-set tuning.
- **proxymock-load-test**: the `load` route; one flat-load run with latency,
  throughput, and match-rate reporting.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

The proof is hermetic (no cloud, no live downstream, no app build, no
servers). It runs `doctor` against this repo and verifies exit 0 with the
committed `lab/proxymock/recording` and its staged blueprint reported; runs
`doctor` against an empty directory and verifies exit 1 with the missing
recording named; smoke-tests every route by dispatching `--help` and
verifying exit 0 with the correct sibling script's usage text answering;
and verifies a bogus route and a bare invocation both exit 2 with usage.
