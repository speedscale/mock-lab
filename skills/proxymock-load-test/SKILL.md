---
name: proxymock-load-test
description: Run a quick load test by replaying recorded proxymock RRPair traffic at a target with parallel virtual users, then report latency percentiles, throughput, and match rate. Use when users ask for a load test, stress test, or to push concurrent traffic at a local app or service using recorded proxymock traffic.
argument-hint: --in <dir> --test-against <url> [--vus N | --sessions N | --stage vus=N,for=D] [--for 30s | --times N] [--performance]
---

# proxymock Quick Load Test

Turn a recording into a load test. `proxymock replay` already replays recorded
RRPair requests; with `--vus` (virtual users) and `--for`/`--times` it becomes a
realistic load generator that reuses traffic the app actually saw, so the load
is shaped like production instead of a synthetic script.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: directory of test/recording RRPair files to drive (the inbound
  requests to your app, e.g. a recording's `localhost/` subdir, or a whole
  recording).
- `--test-against`: the target to hit (e.g. `http://localhost:8080`). Any part
  of the address you supply overrides that part of each recorded request.
- `--vus`: parallel virtual users (default 4).
- `--for` / `--times`: load shape — run for a duration (loops the set) or a
  fixed number of passes. Default is `--for 10s`.
- `--sessions`: replay N recorded *sessions* concurrently instead of virtual
  users (see below). Overrides `--vus`.
- `--stage`: one leg of a load ramp, repeatable (see below). Self-contained,
  so it replaces `--vus` / `--sessions` / `--for` / `--times`.
- `--fail-if`: SLO gate, repeatable; trips a nonzero exit (see below).
- `--performance`: opt-in high-throughput mode (see below). Not combinable
  with a `--fail-if` on `requests.result-match-pct`.

Run the bundled script:

```bash
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in <recording-or-localhost-dir> \
  --test-against http://localhost:8080 \
  --vus 8 --for 30s
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-load-test` with the copied skill directory.

## Offline load test (no network)

The target app's own downstream can be mocked so the whole load test runs
offline. Start the app under `proxymock mock` in one terminal, then load it in
another:

```bash
# terminal 1 — app with its downstream mocked from the committed recording
cd languages/go && proxymock mock --in ../../lab/proxymock/recording -- go run .
# terminal 2 — push load at the app
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in lab/proxymock/recording/localhost \
  --test-against http://localhost:8080 --vus 8 --for 20s
```

## High-throughput mode (--performance)

For pure-load runs where match rate does not matter, pass `--performance`.
The script's own flag name is unchanged, but as of proxymock v2.5.805 it
forwards `proxymock replay --load-test`: the flag was renamed, and the old
`--performance` still works but prints `Flag --performance has been
deprecated, use --load-test instead` on every run. The mode skips
per-response match scoring and granular response collection on the
generator. Combined with starting the mock side as `proxymock mock --no-out
...` (skip writing every observed pair to disk, the biggest mock-side CPU
cost), profiling on an 18-core M-series host measured +67% throughput (13.7k
to 22.9k rps) and p99 down from 52 to 28 ms on identical hardware versus
default flags — that is high-throughput mode plus `mock --no-out` against a
default replay writing every pair to disk, so it is a both-sides figure, not
the effect of the replay flag alone.

The caveat: `--load-test` omits `requests.result-match-pct` from the results
entirely, because responses are not scored. The summary reports `matchPct`
as null with an explanatory note instead of a number, and the script refuses
a `--fail-if` on `requests.result-match-pct` when `--performance` is set. It
is opt-in, not the default, because the default mode's match data is what
several consumers (and the Interpretation section below) gate on.
`--load-test` also writes no replay output directory at all — no RRPair
files and no `replay-verdict.json` — so nothing downstream can read per-pair
results from a high-throughput run.

## Load shape: sessions and ramps

`--vus` is the default shape: every virtual user loops the whole traffic set
as fast as it can. Two alternatives cover shapes it cannot express:

- `--sessions N` replays N recorded **sessions** concurrently instead. Each
  slot takes one recorded actor's requests and replays them in order,
  preserving the recorded think-time, so the app sees a realistic distinct
  actor per slot rather than N copies of the full set at full tilt. Expect
  far lower rps than `--vus` at the same N — think-time is the point.
  Combinable with `--for` / `--times`.
- `--stage vus=N,for=D,ramp=D` describes one leg of a ramp and is repeatable;
  legs run in order. `ramp` sits *inside* `for` (minimum 5s), not added to
  it, and `sessions=N` may be used in place of `vus=N`. A stage carries its
  own target and duration, so `--stage` cannot be combined with `--vus`,
  `--sessions`, `--for` or `--times`; the script rejects the combination up
  front rather than letting the replay fail after load is already flowing.

```bash
# 20 recorded actors, each replaying its own journey at recorded think-time
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in ./recording/localhost --test-against http://localhost:8080 \
  --sessions 20 --for 2m

# warm up at 5 VUs, then ramp to 50 over a minute and hold
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in ./recording/localhost --test-against http://localhost:8080 \
  --stage vus=5,for=30s --stage vus=50,for=2m,ramp=1m
```

The summary shape is identical for all three, so `--fail-if` gates and the
`summary.json` contract are unchanged.

## SLO gating with --fail-if

Pass one or more `--fail-if` conditions to make the run a pass/fail gate (handy
in CI). The script exits nonzero when any condition is true:

```bash
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in ./recording/localhost --test-against http://localhost:8080 \
  --vus 8 --for 30s \
  --fail-if 'latency.p99>150' \
  --fail-if 'requests.failed!=0'
```

Valid metrics: `latency.{avg,min,max,p50,p75,p90,p95,p99}`,
`requests.{total,succeeded,failed,per-second,per-minute,response-pct,result-match-pct}`.

## Output

`summary.json` (and the raw `result.json`) are written to the work dir. The
summary carries the aggregate (`-ALL-`) metrics plus a per-endpoint breakdown:

- `latencyMs`: min/avg/p50/p90/p95/p99/max (milliseconds).
- `rps` / `rpm`: throughput.
- `totalRequests`, `succeeded`, `failed`.
- `matchPct`: percent of responses that matched the recorded response. A load
  test cares mostly about latency, throughput, and `failed`; a low `matchPct`
  is expected when responses carry per-call values (tokens, IDs, timestamps)
  and is a correctness signal for the **proxymock-replay-tuning** skill, not a
  load failure. Under `--performance` it is null (`--load-test` omits the
  metric because responses are not scored) and `matchPctNote` says so.

When reporting results, lead with p95/p99 latency, RPS, and failed count, and
include the absolute path to `summary.json`.

## Interpretation

- **Rising p99 as `--vus` climbs** — the app or a downstream is saturating;
  step `--vus` up (4 → 8 → 16) to find the knee. **proxymock-perf-container**
  automates that ladder and refuses to call generator saturation an app limit.
- **Low rps under `--sessions`** — expected, not a finding. Sessions preserve
  recorded think-time, so throughput reflects the recorded pacing rather than
  the app's ceiling. Use `--vus` when you want a ceiling.
- **`failed` > 0** — the target returned transport errors or timed out under
  load; check the app log, not the recording.
- **`matchPct` low but `failed` 0** — the app is fast and healthy; responses
  just differ from the recording (dynamic fields). Hand off to
  proxymock-replay-tuning if you need a clean match rate too.

## Proof

```bash
./skills/proxymock-load-test/scripts/prove-proxymock-load-test.sh
```

The proof starts the mock-lab Go app with its downstream mocked from the
committed recording, drives a multi-VU load test at it, and verifies the run
produced real throughput with zero failed requests and populated latency
percentiles.
