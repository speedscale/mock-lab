---
name: proxymock-perf-container
description: Load-test one service with its downstream mocked by replaying recorded traffic with proxymock replay --vus --for --load-test, and judge the result honestly - how to tell an app limit from test-harness saturation, why cross-run rps comparison on a shared host is meaningless, and which figure survives a move to a sized container. Use when users ask what a container or service can sustain, want load numbers from recorded traffic, or need to know whether a throughput ceiling is the app or the harness.
argument-hint: --in <recording-dir> --test-against <url> --vus N --for D [--load-test]
---

# proxymock Perf Container

Answer "what can THIS container sustain?" for one service in isolation: its
downstream is mocked, so the numbers describe the service, not its
dependencies. One native command:

```bash
proxymock replay \
  --in ./proxymock/recording/localhost \
  --test-against http://localhost:8080 \
  --vus 16 --for 30s --load-test
```

**Requires proxymock v2.5.814 or newer.**

There is no CPU sampler in this repo any more. Judging the result honestly is a
reading skill, and the rest of this document is that skill. The measured
thresholds below are the whole product.

## Works with your stack (no bash required)

Isolate the service first, then load it:

```bash
# 1. start the app with its downstream mocked (--no-out keeps the mock out of
#    the measurement; it writes every observed pair to disk otherwise)
proxymock mock --in ./proxymock/recording --no-out -- <your app command>

# 2. load it
proxymock replay --in ./proxymock/recording/localhost \
  --test-against http://localhost:8080 --vus 16 --for 30s --load-test

# 3. optional SLO gate, exits 1 when a threshold trips
proxymock replay --in ./proxymock/recording/localhost \
  --test-against http://localhost:8080 --vus 16 --for 30s --load-test \
  --fail-if "latency.p99 > 50" --fail-if "requests.failed != 0"
```

| Exit | Meaning |
| --- | --- |
| `0` | the run completed (and every `--fail-if` check passed) |
| `1` | a `--fail-if` check tripped, or the run did not complete |

Load shapes beyond a flat VU level: `--sessions N` replays one recorded actor
per slot in order at recorded think-time (realism), and `--stage
vus=N,for=D,ramp=D` builds a multi-leg ramp. A flat `--vus` level is what you
want for a capacity ladder, because rungs have to be comparable.

`--load-test` disables per-response match scoring, so
`requests.result-match-pct` is not reported. That is the honest choice for a
load run — no scoring overhead riding on the generator's back — but it means
this run says nothing about correctness. Correctness over the same recording is
**proxymock-regression-test**'s job. Drop `--load-test` if you want match rates
back.

## Judging the number honestly

The load generator and the app usually share a host, and on that setup the
generator saturates the host well before an efficient app does, **with zero
failed requests the whole way**. No field in the replay output attributes the
ceiling, so a naive report calls host saturation an app limit. These are the
measured rules for refusing to do that.

**Treat a level as harness-bound when either holds:**

- **host idle < ~20%**, or
- **(generator + mock) CPU > ~2x app CPU.**

The mock server is test infrastructure and must be counted. Measured at VU 4:
app 128%, generator 248%, mock 229%, host idle 26%. Generator-only, the ratio
is 248/128 = 1.9x, under the threshold, and the level reads clean — blessing
11,639 rps as an app number while test infrastructure burned 3.7x the app's
CPU. Counting the mock puts harness at 475% against 2x app 256% and the level
is correctly refused.

A harness-bound level describes the test harness, not the app. Do not quote an
app ceiling from one. The app may well sustain more; rerun the upper levels
from a separate load host (or the Kubernetes generator) if the answer matters.
Co-located generators on this class of host saturate around VU 200 against a
trivial app.

Note the host-idle rule reads the **whole host**, so unrelated background load
trips it. That is correct — perf numbers from a busy host are not app numbers —
but it means CI runners need a quiet or pinned host.

Measure CPU from cumulative cputime deltas between samples, not from `ps`'s
`%cpu` column: that column is a decaying lifetime average and under-reports a
long-lived app under a short burst (measured: an app serving 4k rps read 1%).

## What comparisons are valid

- **Within one run: yes.** Repeat samples at a fixed VU level in the same
  session spread about **1%**. Take several, let the worst one gate, and that
  comparison is sound. This is what any margin setting is actually covering.
- **Across runs on a contended host: no.** The same VU level against the same
  build measured **9,067 rps and 11,597 rps** on separate runs — **27% apart**
  — while within-run spread stayed at ~1%. No margin rescues that: 30% hides
  real regressions, 10% fails runs that changed nothing. Re-establish the
  baseline on the host you are gating on, in the same session, and compare
  against that.
- **Prefer efficiency for anything that travels.** A raw rps ceiling is a fact
  about this host. **rps per app-core** survives a move to a sized container:
  measured on this lab's app it held between **7,800 and 9,600 rps per
  app-core from VU 1 to VU 50** (~8,600 typical), so a 5,000 rps budget needs
  roughly 0.6 app-cores.

## What the latency numbers mean

- **p99 at 1 ms is the service's own overhead** with the downstream mocked. It
  excludes real downstream RTT entirely, so it is not a production latency
  figure — it is the floor your service adds.
- Latency percentiles are integer milliseconds, so sub-5 ms p50/p95 deltas are
  rounding artifacts, not regressions.
- **`failed` > 0 at some level**: transport errors or timeouts under load.
  Check the app log at that level before trusting the rps.

## Finding the knee by hand

Walk a ladder in ascending order (`1,4,16,50`) and look for the first level
whose rps gain over the previous level falls under ~10%. That is the plateau;
the knee is the level before it, and sustainable throughput is reported there —
never at the max VU level, which typically buys a little rps for a lot of p99.
Exclude harness-bound levels from the search entirely; a plateau made of
harness-bound rungs is a measurement of the generator.

## Related

- **proxymock-load-test**: the flat-load skill with `--fail-if` SLO gates and
  its own script, if you want a wrapper.
- **proxymock-regression-test**: the correctness gate over the same recording.
  Run it before trusting perf numbers from a build that may have behavior
  regressions.
- **proxymock-chaos-mock**: drive this load while the downstream is slow or
  flaky.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

One shared proof covers this pack (a documented deviation from the repo's
one-prove-per-skill convention: every skill runs the same native binary now).
The case covering this skill runs the documented load command against a stub of
the committed recording and asserts exit 0, plus a `--fail-if` gate that trips
and exits 1. The honesty thresholds above cannot be proven hermetically — they
fire on host saturation — which is exactly why they are documented as reading
rules rather than automated into a gate that would lie on a quiet CI box.
