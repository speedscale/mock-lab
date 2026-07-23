---
name: proxymock-perf-container
description: Load-test a single service with its downstream mocked by replaying recorded traffic up a virtual-user ladder, report sustainable throughput at the knee, and gate rps/p99 budgets there with margins while per-level CPU attribution refuses to pass off load-generator saturation as an app limit. Use when users ask what a container or service can sustain, want a performance budget gate on recorded traffic, or need load numbers that distinguish app saturation from harness saturation.
argument-hint: --in <recording-dir> --test-against <url> [--vus-ladder "1,4,16,50"] [--for 30s] [--assert-rps N] [--assert-p99 Nms] [--margin-pct 10] [--repeats 2]
---

# proxymock Perf Container

Answer "what can THIS container sustain, and is it within budget?" for one
service in isolation: its downstream is mocked, so the numbers describe the
service, not its dependencies. The skill walks a virtual-user ladder, finds
the throughput knee, and evaluates assertions there, at the sustainable
level, never at the max VU level (which typically buys a little rps for a lot
of p99). It builds on the **proxymock-load-test** skill: each ladder level is
one run of that skill's script, so replay flags and metric parsing live in
one place.

The core of the skill is an honesty gate. The load generator and the app
usually share a host, and on that setup the generator saturates the host well
before an efficient app does, with zero failed requests the whole way; the
replay output contains no field attributing the ceiling. Measured externally
at the ceiling, the generator burned roughly 10x the app's CPU with host idle
at 1-2%, so a naive report calls host saturation an app limit. This skill
samples CPU for the generator, the app, and the host during every run and
refuses to make app-limit claims from harness-bound levels. Empirically
verified.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: directory of recorded RRPair files to drive (the inbound requests
  to your app, e.g. a recording's `localhost/` subdir).
- `--test-against`: the target to load (e.g. `http://localhost:8080`).
- `--vus-ladder`: comma-separated ascending VU levels (default `1,4,16,50`).
- `--for`: duration per ladder level (default `30s`).
- `--assert-rps`: sustainable throughput must be at least this many rps at
  the assertion level.
- `--assert-p99`: p99 latency must be at most this many ms at the assertion
  level (accepts `50` or `50ms`).
- `--margin-pct`: margin applied to both assertions (default 10; the
  measured rps spread across repeat runs at a fixed VU level was 4.8%, so 10
  absorbs run-to-run variance without hiding real misses).
- `--repeats`: total samples at the assertion level, the ladder run plus
  repeat runs, and the WORST sample gates pass/fail (default 2). A
  conservative gate: one bad sample fails the run.
- `--pin-vus`: evaluate assertions at this ladder level instead of the
  detected knee.
- `--work-dir`: where per-level runs and `summary.json` land.
- `--load-test-script`: path to `proxymock-load-test.sh` when the sibling
  skill is not in its default location.
- `--proxymock`: proxymock binary, forwarded to the load-test script.

Run the bundled script:

```bash
# report-only: find the knee and the sustainable rate
./skills/proxymock-perf-container/scripts/proxymock-perf-container.sh \
  --in ./proxymock/recording/localhost --test-against http://localhost:8080

# budget gate for CI: assert at the knee with margins
./skills/proxymock-perf-container/scripts/proxymock-perf-container.sh \
  --in ./proxymock/recording/localhost --test-against http://localhost:8080 \
  --vus-ladder "1,4,16,50" --for 30s \
  --assert-rps 2000 --assert-p99 50ms --margin-pct 10 --repeats 2
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-perf-container` with the copied skill directory, copy the
`proxymock-load-test` skill alongside it (this skill drives its script), or
point `--load-test-script` at a copy.

To isolate the service, start it with its downstream mocked before loading it
(see the offline recipe in proxymock-load-test):

```bash
cd go && proxymock mock --in ../lab/proxymock/recording -- go run .
```

## Knee finding

The ladder runs in ascending order. The first level whose rps gain over the
previous level falls under 10% marks the plateau; the knee is the previous
level, and sustainable throughput is reported there. When no plateau appears
within the ladder, the top level is reported with an explicit "no plateau
within ladder; true knee may be higher" caveat. Harness-bound levels (below)
are excluded from knee detection entirely.

## The honesty gate

During every run the script samples, roughly once a second:

- generator CPU: processes whose command line contains `proxymock replay`
  AND that descend from this run's load-test invocation, so a concurrent
  proxymock session elsewhere on the host does not pollute attribution
  (observed in practice: another session's replay burning 600% CPU);
- app CPU: the process(es) listening on the target port, local targets only
  (found via `lsof`; non-local targets get no app attribution and the
  generator-vs-app check is skipped);
- host idle: `top` on macOS, `/proc/stat` on Linux, platform auto-detected.

Process CPU is computed from cumulative cputime deltas between samples, not
from `ps`'s `%cpu` column: that column is a decaying lifetime average and
under-reports a long-lived app under a short burst (measured: an app serving
4k rps read 1%).

A level is HARNESS-BOUND when host idle drops under 20%, or the generator
burns at least a full core and more than 2x the app's CPU (the full-core
floor keeps near-idle low-VU levels from tripping the ratio test). Harness
bound levels are reported as `harness-bound above VU~N`, excluded from knee
detection and app-limit claims, and an assertion that depends on one exits
with a distinct code. An app ceiling is never printed from a harness-bound
level. Co-located generators on this class of host saturate around VU200
against a trivial app, so subsystem-scale load needs a separate load host
(or the Kubernetes generator) for honest numbers at high VU counts. Note the
host-idle check reads the whole host: unrelated background load also trips
it, which is correct (perf numbers from a busy host are not app numbers)
but means CI runners need a quiet host or a pinned, isolated one.

Two test hooks exist for the proof script only, both clearly non-production:
`PERF_FORCE_HARNESS_BOUND=1` forces every level harness-bound (the real gate
fires on host saturation, which a hermetic proof cannot force), and
`PERF_FORCE_HARNESS_CLEAN=1` forces every level clean (the real gate cannot
be suppressed hermetically on a host busy with unrelated work).

## Output contract

Written to `--work-dir` (default a timestamped dir): `vus-<N>/` per ladder
level and `repeat-<i>/` per extra assertion-level sample (each holding the
load-test run's `load/summary.json` plus `cpu-samples.csv`), `ladder.json`
(intermediate), and `summary.json` with the ladder table, the knee, the
assertion-level samples with worst-of rps/p99, per-level CPU attribution and
harness-bound flags, the verdicts, and absolute paths. The human summary
prints the same, one ladder line per level.

Exit codes:

- `0`: assertions pass at the assertion level, or no assertions were given
  (report-only).
- `2`: an assertion failed on the worst sample at the assertion level.
- `3`: the assertion level is harness-bound (or every level is, so no
  assertion level exists): the run cannot answer the assertion. Distinct
  from `2` because the result is unusable, not failing.
- `4`: precondition failure (bad args, missing dirs, a load run did not
  complete).

## Interpretation

- **Knee found, harness clean, assertions pass**: the sustainable line is a
  real app number; the knee VU level and rps are the capacity claim.
- **`harness-bound above VU~N`**: levels above N describe the generator, not
  the app. The app may well sustain more; rerun the upper levels from a
  separate load host if the answer matters.
- **Exit 3 on a gated run**: do not treat as a perf failure. The harness
  saturated at the level the assertion needed; nothing about the app was
  proven either way.
- **p99 under 5 ms at the assertion level**: latency percentiles are integer
  milliseconds, so sub-5ms p50/p95 deltas are rounding artifacts, not
  regressions. The summary flags this, and the skill gates only on rps and
  p99 by design.
- **`matchPct` below 100 with `failed` 0**: succeeded-but-unmatched
  responses (rotating tokens, moving IDs) count toward matchPct, not
  failures. It is reported for context but never gated here; correctness
  gating over the same recording is **proxymock-regression-test**'s job.
- **`failed` > 0 at some level**: transport errors or timeouts under load;
  check the app log at that level's `load.out` before trusting rps there.

## Related

- **proxymock-load-test**: the engine this skill drives, one run per ladder
  level. Use it directly for a single flat-load run with `--fail-if` SLO
  gates; use this skill for knee finding, repeat sampling, and CPU
  attribution on top of it.
- **proxymock-regression-test**: the correctness gate over the same
  recording; run it before trusting perf numbers from a build that may have
  behavior regressions.
- **proxymock-compare-results**: deep before/after comparison when two perf
  runs disagree and you need to know what else changed.

## Proof

```bash
./skills/proxymock-perf-container/scripts/prove-proxymock-perf-container.sh
```

The proof is hermetic (no cloud, no live downstream, no app build). It
starts a local stub that answers every recorded endpoint, then drives the
script through four sub-cases: a `1,2` ladder with no assertions exits 0 and
`summary.json` carries the ladder with per-level CPU attribution and a knee;
an absurd `--assert-rps 10000000` exits 2; a missing `--in` exits 4; and
`PERF_FORCE_HARNESS_BOUND=1` with a trivially passing assertion exits 3,
proving the harness-bound refusal outranks a passing assertion. The real
harness-bound gate fires on host saturation, which a hermetic proof cannot
force, hence the documented test hook.
