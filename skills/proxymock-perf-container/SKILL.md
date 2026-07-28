---
name: proxymock-perf-container
description: Load-test a single service with its downstream mocked by replaying recorded traffic up a virtual-user ladder, report sustainable throughput at the knee, and gate rps/p99 budgets there with margins while per-level CPU attribution refuses to pass off test-harness saturation (load generator plus mock server) as an app limit. Use when users ask what a container or service can sustain, want a performance budget gate on recorded traffic, or need load numbers that distinguish app saturation from harness saturation.
argument-hint: --in <recording-dir> --test-against <url> [--vus-ladder "1,4,16,50"] [--for 30s] [--assert-rps N] [--assert-p99 Nms] [--margin-pct 10] [--repeats 2] [--no-performance]
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
replay output contains no field attributing the ceiling. Native saturation
attribution is still not available as of proxymock v2.5.805 — replay reports
only latency and request metrics, with no generator CPU, host idle, or
harness-bound signal in any output surface — so this skill measures it
externally. Measured that way at the ceiling, the generator burned roughly
10x the app's CPU with host idle at 1-2%, so a naive report calls host
saturation an app limit. This skill samples CPU for the generator, the mock
server, the app, and the host during every run and refuses to make app-limit
claims from harness-bound levels. Empirically verified.

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
- `--margin-pct`: margin applied to both assertions (default 10). It absorbs
  the spread between the repeat samples of ONE run, measured at ~1%. It
  cannot make a cross-run comparison meaningful; see "What the margin does
  and does not cover".
- `--repeats`: total samples at the assertion level, the ladder run plus
  repeat runs, and the WORST sample gates pass/fail (default 2). A
  conservative gate: one bad sample fails the run.
- `--pin-vus`: evaluate assertions at this ladder level instead of the
  detected knee.
- `--work-dir`: where per-level runs and `summary.json` land.
- `--load-test-script`: path to `proxymock-load-test.sh` when the sibling
  skill is not in its default location.
- `--proxymock`: proxymock binary, forwarded to the load-test script.
- `--no-performance`: disable the default high-throughput replay mode. By
  default every load run passes the load-test script's `--performance` flag,
  which as of proxymock v2.5.805 forwards `proxymock replay --load-test` (the
  flag was renamed; `--performance` still works upstream but prints a
  deprecation notice). It skips per-response match scoring on the generator.
  This skill never gates on match rate, so the default only makes the numbers
  more honest: the reported rps and p99 are pure load figures, with no
  scoring overhead riding on the generator's back (profiling on an 18-core
  M-series host measured +67% throughput and p99 52 to 28 ms for
  high-throughput replay plus `mock --no-out` versus defaults). The cost is
  that `matchPct` is not scored and shows as `not scored` in the ladder;
  opt out if you want match rates in the report.

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
point `--load-test-script` at a copy. The scripts also source shared helpers
from `skills/lib/common.sh` (resolved as `../../lib/common.sh` relative to
the scripts), so copy that file alongside.

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
- mock CPU: processes whose command line contains `proxymock mock` and that
  belong to this run (see below). The mock server is test infrastructure too,
  and it burns CPU comparable to the generator;
- app CPU: the process(es) listening on the target port, local targets only
  (found via `lsof`; non-local targets get no app attribution and the
  harness-vs-app check is skipped);
- host idle: `top` on macOS, `/proc/stat` on Linux, platform auto-detected.

Process CPU is computed from cumulative cputime deltas between samples, not
from `ps`'s `%cpu` column: that column is a decaying lifetime average and
under-reports a long-lived app under a short burst (measured: an app serving
4k rps read 1%).

**Harness CPU is generator + mock.** Counting the generator alone lets a
level pass where the load harness is the thing running the host. Measured at
VU 4 on a run the generator-only gate called clean: app 128%, generator 248%,
mock 229%, host idle 26%. The old ratio test computed 248/128 = 1.9x, under
its 2x threshold, and blessed 11,639 rps as an app number, while test
infrastructure was actually burning 3.7x the app's CPU. Counting both puts
harness at 475% against 2x app 256% and the level is correctly refused.

Attributing the mock takes two paths, because the documented workflow starts
it separately rather than under this script:

- the mock **descends from this run**, when the whole run was started under
  it; or
- the mock is an **ancestor of the app process**, which is the un-wrapped
  case: `proxymock mock --in <recording> -- go run .` runs the app as its own
  child, so walking up from the pid `lsof` found on the target port reaches
  it.

A `proxymock mock` process matching neither belongs to someone else's session
on the host. It is reported as unattributable and the comparison **falls back
to the generator alone**, with a note in the output and `mockAttributed:
false` in `summary.json`. A bare `pgrep -f proxymock` would grab the foreign
process and silently inflate the verdict; guessing is worse than saying the
mock could not be attributed.

A level is HARNESS-BOUND when host idle drops under 20%, or harness CPU is at
least a full core and more than 2x the app's CPU (the full-core floor keeps
near-idle low-VU levels from tripping the ratio test). Harness-bound levels
are reported as `harness-bound above VU~N`, excluded from knee detection and
app-limit claims, and an assertion that depends on one exits with a distinct
code. An app ceiling is never printed from a harness-bound level. Co-located
generators on this class of host saturate around VU200 against a trivial app,
so subsystem-scale load needs a separate load host (or the Kubernetes
generator) for honest numbers at high VU counts. Note the host-idle check
reads the whole host: unrelated background load also trips it, which is
correct (perf numbers from a busy host are not app numbers) but means CI
runners need a quiet host or a pinned, isolated one.

## What the margin does and does not cover

`--margin-pct` covers the spread **within one run**. Across the repeat
samples of a single run at a fixed VU level, measured spread is ~1%, and that
is what `--repeats` plus worst-sample gating is built on: several samples
taken back to back under the same host conditions, with the worst one gating.

It does not cover comparisons **across runs**. On a host with unrelated
background load, the same VU level against the same build measured 9,067 rps
and 11,597 rps on separate runs -- 27% apart, while within-run spread stayed
at ~1%. No margin setting rescues that: a 30% margin would hide real
regressions, and a 10% margin fails runs that changed nothing. An earlier
version of this document cited a 4.8% run-to-run spread and recommended 10%
on that basis; that figure came from a quiet host and does not hold on a
contended one.

So:

- **Gate within a single run.** Give the run its `--repeats` samples and let
  the worst one decide. That comparison is valid.
- **Do not compare against yesterday's number** from a different run unless
  the host conditions were the same. Re-establish the baseline on the host
  you are gating on, in the same session, and compare against that.
- **Prefer `rpsPerAppCore` for anything that travels.** A raw rps ceiling is
  a fact about this host; rps per app-core survives a move to a sized
  container. Measured on this lab's app it held between 7,800 and 9,600 rps
  per app-core from VU 1 to VU 50, so a 5,000 rps budget needs roughly 0.6
  app-cores.

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

Per-level CPU is reported split, not blended, so a reader can see where the
host went: `generatorMaxPct`, `mockMaxPct`, `harnessMaxPct` (generator +
mock, the peak of the per-interval sum, so it never adds two peaks that
happened seconds apart), `appMaxPct`, `hostIdleMinPct`, plus
`mockAttributed`. Each level also carries `rpsPerAppCore`, the rps the app
sustained per core of its own CPU: the figure that survives a move to a
differently sized container, where a raw rps ceiling does not.

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
- **`harness-bound above VU~N`**: levels above N describe the test harness,
  not the app. Read the `gen=` and `mock=` split on that ladder line to see
  which half is doing it. The app may well sustain more; rerun the upper
  levels from a separate load host if the answer matters.
- **`mock=n/a` with a note that the mock could not be tied to this run**: a
  `proxymock mock` process is on the host but is neither a descendant of the
  run nor an ancestor of the app, so it was left out rather than guessed at.
  Harness CPU is the generator alone and is therefore a floor, not the whole
  figure. Start the app under its mock (`proxymock mock --in <recording> --
  <app>`) to get the mock counted.
- **Exit 3 on a gated run**: do not treat as a perf failure. The harness
  saturated at the level the assertion needed; nothing about the app was
  proven either way.
- **p99 under 5 ms at the assertion level**: latency percentiles are integer
  milliseconds, so sub-5ms p50/p95 deltas are rounding artifacts, not
  regressions. The summary flags this, and the skill gates only on rps and
  p99 by design.
- **`match=not scored` in the ladder**: the default high-throughput mode
  skips match scoring (`replay --load-test` omits
  `requests.result-match-pct` outright; see `--no-performance`), so no match
  rate exists to report and `matchPct` is null in `summary.json`. This is expected, not a
  data problem. With `--no-performance`, `matchPct` below 100 with `failed`
  0 means succeeded-but-unmatched responses (rotating tokens, moving IDs);
  reported for context but never gated here; correctness gating over the
  same recording is **proxymock-regression-test**'s job.
- **`failed` > 0 at some level**: transport errors or timeouts under load;
  check the app log at that level's `load.out` before trusting rps there.

## Related

- **proxymock-load-test**: the engine this skill drives, one run per ladder
  level. Use it directly for a single flat-load run with `--fail-if` SLO
  gates; use this skill for knee finding, repeat sampling, and CPU
  attribution on top of it. It also exposes proxymock's `--sessions`
  (recorded actors replayed in order at recorded think-time) and `--stage`
  (multi-leg ramps) shapes. This skill deliberately does not use them: the VU
  ladder needs a flat, comparable level per rung, which is exactly what
  `--vus` gives and what a ramp or a think-time-paced session does not. Reach
  for those shapes in proxymock-load-test when you want realism or a ramp
  profile rather than a capacity ceiling.
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
script through five sub-cases: a `1,2` ladder with no assertions exits 0 and
`summary.json` carries the ladder with per-level CPU attribution and a knee;
an absurd `--assert-rps 10000000` exits 2; a missing `--in` exits 4;
`PERF_FORCE_HARNESS_BOUND=1` with a trivially passing assertion exits 3,
proving the harness-bound refusal outranks a passing assertion; and a stub
wrapped in `proxymock mock` proves the mock is attributed through the app's
ancestry and counted in harness CPU, where the first four cases cover the
fallback with no attributable mock. The real harness-bound gate fires on host
saturation, which a hermetic proof cannot force, hence the documented test
hook.

The gate's effect was measured outside the proof, against this lab's Go app
started under `proxymock mock`. At VU 4: app 128%, generator 248%, mock 229%,
host idle 26% (so the idle check did not fire). Generator-only, the level
reads clean and `--assert-rps 5000` passes on 11,639 rps. Counting the mock,
harness CPU is 475% against 2x app 256%, the level is refused, and the run
exits 3. VU 1 and VU 16 were harness-bound under both rules, so the verdict
change is confined to the band where the mock was the deciding term.
