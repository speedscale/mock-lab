---
name: quality-loop
description: Route a development intent to the right native proxymock command (regression gate, incident fix verification, load, chaos resilience, contract conformance) or to the repo's analysis skills (comparison, summarization, match-rate tuning, load), and get a repo into the traffic quality loop with one recording. Includes a doctor that checks the proxymock version, recordings, blueprints, runtime proxy support, and ports. Use when users ask how to test a change with recorded traffic, which proxymock command applies to a task, to set up the quality loop in a repo, or to check whether the environment is ready.
argument-hint: <doctor|regression|verify-fix|load|chaos|contract|compare|summarize|tune|load-test> [args...]
---

# proxymock Quality Loop

The loop: capture real traffic once -> keep it as a snapshot (RRPair files) ->
run your code against the snapshot -> act on the diff. One snapshot feeds every
tier: the same recording is the regression gate's input, the mock's source
data, the load test's request script, and the chaos variant's raw material.
Nothing below asks for a second capture.

**Requires proxymock v2.5.814 or newer.** Every fact in this pack was measured
on that release. Older builds differ on connection faults, native body scoring,
`--require-blueprint`, `proxymock validate`, and process teardown, so the
guidance here will mislead you on them. `quality-loop.sh doctor` warns when the
installed CLI is older.

## The native commands are the product

proxymock does the work. Each intent below is one CLI invocation, and its exit
code is the CI contract. The dispatcher script in this skill is optional
convenience: it builds the same line, execs it, and passes the exit code
straight through — no verdict of its own, no summary file of its own, no
reformatting of proxymock's output. Anyone on k6, bruno, postman-cli, or no
shell script at all runs the raw command and gets the identical result.

| Intent | Native command | Exits |
| --- | --- | --- |
| Did my change break anything? | `proxymock replay --in <rec> --test-against <url> --baseline <prior> --fail-on-new-mismatch` | 0 pass / 3 new mismatch |
| Is the incident fixed? | `proxymock replay --in <incident> --test-against <url> --verify-fix [--expect <re>]` | 0 fixed / 2 still reproduces / 3 collateral |
| Does the dependency match its spec? | `proxymock validate --spec <spec> --in <rrpairs>` | 0 conformant / 2 violations / 3 no spec route |
| What does a lying downstream do to my app? | `proxymock mock --in <rec> --fault '<pat>:<actions>' [-- <app cmd>]` | runs until stopped |
| What can this service sustain? | `proxymock replay --in <rec> --test-against <url> --vus N --for D --load-test` | 0 / 1 on `--fail-if` |

Each skill's SKILL.md carries the full exit-code table, the flags worth
knowing, and how to read the result. Start there, not with the script.

## Routing

| Intent sounds like | Route | Where the detail lives |
| --- | --- | --- |
| "Did my change break anything?", pre-ship check, CI gate | `regression` | **proxymock-regression-test** |
| "Prod incident: reproduce it and prove the fix" | `verify-fix` | **proxymock-verify-fix** |
| "What can this service sustain?", load numbers | `load` | **proxymock-perf-container** |
| "How does it behave when the downstream misbehaves?" | `chaos` | **proxymock-chaos-mock** |
| "Does my dependency match its spec?" | `contract` | **proxymock-contract-test** |
| "What changed between these two runs?" | `compare` | **proxymock-compare-results** |
| "What is in this recording?" | `summarize` | **proxymock-summarize-recording** |
| "Replay misses the mock", match-rate tuning | `tune` | **proxymock-replay-tuning** |
| "Flat load run with SLO gates and a summary file" | `load-test` | **proxymock-load-test** |

The first five routes build and exec a native command. The last four dispatch
the repo's own analysis skill scripts unchanged. `load` and `load-test` are
both here on purpose: `load` builds the native load command, `load-test` runs
the `proxymock-load-test` script, which adds its own SLO gating and summary
file on top.

Tie-breakers:

- **regression vs verify-fix** is decided by which recording you hold. A
  healthy recording plus "did I break it" is `regression`. An incident capture
  (recorded errors are the truth) plus "is it fixed" is `verify-fix`.
- **contract vs regression** is decided by which side of the boundary. A
  dependency with a spec is `contract`; your own app, whose contract IS the
  recording, is `regression`.
- **compare / summarize / tune** are analysis routes over result or recording
  dirs; they do not drive traffic at your app.

## One-time setup (add water)

1. **Record once.** From the app's own directory run
   `proxymock record -- <app command>`, then drive real traffic at it (the
   repo's test driver, a curl pass over every endpoint, a browser session). In
   this repo: `cd go && proxymock record -- go run .` plus
   `./lab/tests/run_tests.sh --recording` from the root.
2. **Keep the recording.** Commit it as the baseline snapshot; RRPairs are
   markdown and diff cleanly. This repo ships one at `lab/proxymock/recording`.
3. **Create the comparison baseline.** Run `proxymock replay` once against a
   known-good build and keep its `--out` dir. From then on gate
   baseline-relative, so the deterministic noise floor cannot false-positive.
4. **Stage blueprints if the app has moving IDs** (rotating tokens, generated
   order ids). See the next section — this is the step that silently costs you
   the signal when it goes wrong.

`quality-loop.sh doctor` verifies all of this and exits 0 healthy / 1 missing
preconditions / 2 usage.

## Blueprints: anchoring, and the hostname trap

- **Where they load from.** The workspace `proxymock/blueprints/` directory —
  the parent of the recording dir — loads, and a `blueprints/` copy *inside*
  `--in` loads too, because replay reads `--in` recursively.
- **Workspace discovery is not reproducible across identical recordings under
  different names.** Measured: a byte-identical copy of a recording, under a
  different directory name in the same workspace beside the same
  `blueprints/`, did not pick it up (checked repeatedly, and with the recording
  renamed and renamed back). Whatever scopes the workspace lookup is narrower
  than "the parent of `--in`". If a workspace blueprint does not load, put a
  copy inside `--in`; that location loaded in every layout measured. Use that
  as a local workaround only: this repo's blueprint ships at
  `lab/proxymock/blueprints/`, the workspace dir beside the recording, and a
  shared committed blueprint should not be relocated to dodge the quirk.
- **Confirm, do not assume**, with the `Loaded blueprint "<name>" from <path>`
  line in the replay output. Never move a blueprint the log says is loading.
  Blueprints in `~/.speedscale/data/transforms/` load globally on top of
  either location and are not workspace state.
- **The hostname trap.** Replay rewrites the recorded network address to the
  `--test-against` target, so a blueprint filtering on `network_address` binds
  itself to one spelling of that target. Measured on this lab's blueprint while
  it filtered `network_address CONTAINS "localhost"`: `--test-against
  localhost:8080` fired both chains, while `127.0.0.1:8080` **loaded the
  blueprint and fired ZERO chains, with no warning** — same `Loaded blueprint`
  line both times. Without chains firing, auth and moving-ID endpoints 401 and
  regressions on their success paths are undetectable. Filter on
  `detectedLocation` / `detectedCommand` and scope with `services`. A
  loaded-but-inert blueprint is usually this, not a staging problem.
- **`--require-blueprint <name>` is opt-in, not default.** On v2.5.814 it exits
  0 and still writes `<out>/replay-verdict.json` when the blueprint loaded and
  its chains ran; on an unresolvable name it exits 1 and writes **no verdict
  file**. Gating on it trades the entire regression signal for a blueprint
  warning. Cheaper evidence that a chain really ran: grep the replay output for
  `smart_replace`.

## Shared gotchas (apply on every route)

- **Gate on the verdict, never on transport metrics.** `requests.failed` stays
  0 for a status regression: a 201 that becomes a 200 still completes the HTTP
  exchange. The per-pair verdict is the datum.
- **Body scoring is native and default.** Pairs carry `bodyMatch` and
  `bodyChanges[]` of `{severity, kind, endpoint, location, baseline,
  candidate}`. `--ignore-body-changes` restores status-only scoring.
- **Baseline masking compares change sets.** A pair that failed in the baseline
  is exempt from *that same failure* only. Verified: an identical failure stays
  masked (exit 0); a different failure on the same pair is caught as a new
  mismatch (exit 3).
- **Volatile suppression is by FIELD NAME, undocumented, and unstable.**
  `order_id` and an ISO-8601 `created` were suppressed; `total`, `status`,
  `project`, `expires_in` were scored — and a later round measured the opposite
  for a live `order-<16hex>`. Gate on a baseline, never on a raw zero.
- **Recorded-error-reproduced is a match PASS.** Match compares observed
  against recorded, so faithfully replaying a captured 500 passes. This is why
  verify-fix inverts: an all-match run means the bug still reproduces.
- **Incident captures lack the fixed path's downstream traffic**, because the
  buggy handler usually errored before calling its dependency. Union the
  incident capture with a healthy recording (repeated `--in`) when mocking the
  fixed build's downstream, or declare the network dependency.
- **`proxymock mock` needs an explicit `--in`.** It does not discover a
  recording from cwd. Repeated `--in` unions mock sources.
- **Fault patterns are matched against the bare path and host+path only** —
  no scheme, port, or method — so a plausible full-URL pattern matches nothing.
  proxymock warns, but when it WRAPS an app the warning goes to
  `proxymock.log`, not your terminal.
- **`--fault` is startup-only.** Only mock DATA hot-reloads
  (`--mock-reload-interval`). Restarting a mock that WRAPS the app restarts the
  app, so run recovery scenarios un-wrapped with the app started separately.
- **`connection=drop` returns a truncated 200** below its own
  `Content-Length`, which a status-only assertion scores as a pass. `refuse`
  and `reset` are indistinguishable from inside the app; `stall` needs a
  client-side timeout or it hangs.
- **`--response-selection random` is weighted by copy count and noisy** (15/40
  against a 50% expectation). When the failure ratio IS the measurement, use
  `rate=F/N` or round-robin.
- **`validate` treats undocumented response fields as violations**, with no
  flag to downgrade them. Filter or expect it.
- **A malformed RRPair is skipped silently.** The rest of the directory still
  serves, but the warning only appears at `-v -v`, so a bad edit degrades to a
  mysteriously missing endpoint rather than a loud failure.
- **Two concurrent proxymock runs corrupt each other.** Every command ingests
  its `--in` into `<speedscale-home>/data/snapshots/` under one fixed local
  snapshot id, so a second process with a different `--in` overwrites the
  first's `raw.jsonl` and the loser replays the WINNER's recording. It surfaces
  loudly as `references refUuid <uuid> not found in --in` with **no verdict
  file written**, and quietly as a verdict scored against the wrong recording.
  Give each run its own home when anything else on the machine might be running
  proxymock — copy `~/.speedscale/config.yaml` (and `certs/`, or the run mints
  a CA nothing trusts) into a private dir and pass
  `--config <that>/config.yaml`. Global `transforms/` blueprints still load.
- **MCP parity.** `mock_server_start` exposes `fault`, `mock-timing`,
  `mock-reload-interval` and `response-selection`. Still absent:
  `proxy-out-port`, `health-port`, `app-health-endpoint`. `edit_rrpair` is
  body-only.

## The dispatcher (optional)

```bash
# is this repo in the loop, and is the environment ready?
./skills/quality-loop/scripts/quality-loop.sh doctor

# builds and execs: proxymock replay --in ... --test-against ...
#                     --baseline ... --fail-on-new-mismatch
./skills/quality-loop/scripts/quality-loop.sh regression \
  --in ./proxymock/recording --test-against http://localhost:8080 \
  --baseline ./regress-base

# builds and execs: proxymock replay --in ... --verify-fix --expect ...
./skills/quality-loop/scripts/quality-loop.sh verify-fix \
  --in ./incident/recording --test-against http://localhost:8080 \
  --expect '^/api/stats'
```

Every mode prints the command it is about to run to stderr, then execs it, so
the output and exit code you see are proxymock's own. Extra flags are forwarded
verbatim. `PROXYMOCK=/path/to/proxymock` overrides the binary.

`doctor [--root DIR]` reports proxymock presence and version (warning below
v2.5.814), RRPair recording directories with pair counts, blueprint staging per
recording, Node proxy support (`fetch` ignores proxy env vars before 22.21/24;
on supported versions set `NODE_USE_ENV_PROXY=1` plus `NODE_EXTRA_CA_CERTS`),
and whether ports 8080 and 4140 are free. Exit `0` healthy, `1` with a
`MISSING:` list, `2` on usage errors. Warnings — missing blueprints, old Node,
busy ports — do not fail the check.

## Interpretation

- **doctor: MISSING proxymock**: install the CLI; every route needs it.
- **doctor: version warning**: the routes still run, but this pack's documented
  behavior was measured on v2.5.814. Upgrade before trusting a gotcha above.
- **doctor: MISSING recording dirs**: the repo is not in the loop yet. Run the
  one-time setup; nothing here works without a snapshot.
- **doctor: blueprint warning**: only matters if that app has moving IDs. When
  it does, expect 401/404 noise on replay and an undetectable-regression blind
  spot on those endpoints until a blueprint is staged and confirmed loading.
- **doctor: Node version warning**: recording a Node app on that runtime
  captures nothing through the proxy.
- **doctor: busy port warning**: fine when it is your app or an active mock;
  otherwise free the port.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

`demo.sh [regression|contract|chaos|verify-fix]` beside it is the showing path,
not the contract: it seeds four real defects into a temp copy of `go/`, runs the
native commands against them, prints each finding, and cleans up. `PAUSE=1`
steps between scenes for a screencast.

This is the pack's single proof — a documented deviation from the repo's
one-prove-per-skill convention, adopted because all five loop skills now run
the same native binary and per-skill proofs would be five copies of the same
assertions. It is hermetic: no cloud, no live downstream, no app build. It runs
`doctor` against this repo (exit 0) and an empty dir (exit 1), checks the usage
contract (exit 2), then exercises every documented native command against the
committed `lab/proxymock/recording` and asserts the exit-code contract for each
mode.
