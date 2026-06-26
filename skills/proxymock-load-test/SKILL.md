---
name: proxymock-load-test
description: Run a quick load test by replaying recorded proxymock RRPair traffic at a target with parallel virtual users, then report latency percentiles, throughput, and match rate. Use when users ask for a load test, stress test, or to push concurrent traffic at a local app or service using recorded proxymock traffic.
argument-hint: --in <dir> --test-against <url> [--vus N] [--for 30s | --times N]
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
- `--fail-if`: SLO gate, repeatable; trips a nonzero exit (see below).

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
cd go && proxymock mock --in ../lab/proxymock/recording -- go run .
# terminal 2 — push load at the app
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in lab/proxymock/recording/localhost \
  --test-against http://localhost:8080 --vus 8 --for 20s
```

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
  load failure.

When reporting results, lead with p95/p99 latency, RPS, and failed count, and
include the absolute path to `summary.json`.

## Interpretation

- **Rising p99 as `--vus` climbs** — the app or a downstream is saturating;
  step `--vus` up (4 → 8 → 16) to find the knee.
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
