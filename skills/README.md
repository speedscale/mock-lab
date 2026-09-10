# proxymock agent skills

The recordings in this repo power the agent skills below. All of them run against the
committed [`lab/proxymock/recording`](../lab/proxymock/recording) and need no Speedscale
Cloud account. Not sure which one applies? Start with
[`quality-loop`](quality-loop/SKILL.md): it routes an intent to the right command and its
`doctor` checks the environment.

Run the commands in this file from the **repo root**.

**The five loop skills are documentation over native commands.** `proxymock` does the work
itself now, so each of those SKILL.md files shows the raw CLI line and its exit codes, and the
single [`quality-loop.sh`](quality-loop/scripts/quality-loop.sh) dispatcher just builds
that line, execs it, and passes the exit code through. Nothing re-derives a verdict. The four
analysis skills (load-test, compare-results, summarize-recording, replay-tuning) keep their own
scripts and proofs.

**These skills assume proxymock v2.5.814 or newer.** Their guidance was measured on that
release, and older builds differ on connection faults, native body scoring,
`--require-blueprint`, `proxymock validate`, and process teardown.
`./skills/quality-loop/scripts/quality-loop.sh doctor` warns if the installed CLI is older.

| Skill | What it does | Wraps |
| --- | --- | --- |
| [`proxymock-load-test`](proxymock-load-test/SKILL.md) | Replay recorded traffic at a target with parallel virtual users; report latency percentiles, throughput, and match rate, with `--fail-if` SLO gates | `proxymock replay --vus --for --fail-if` |
| [`proxymock-compare-results`](proxymock-compare-results/SKILL.md) | Deep before/after comparison of two replay/recording sets — what regressed, improved, or persisted across performance/reliability/security; writes JSON, HTML, and an LLM digest | `proxymock report --baseline` + `proxymock drift` |
| [`proxymock-summarize-recording`](proxymock-summarize-recording/SKILL.md) | Summarize a recording: hosts, inbound/outbound endpoints, methods, status mix, volume, plus the report digest | `proxymock report --format prompt` |
| [`proxymock-regression-test`](proxymock-regression-test/SKILL.md) | Replay a recording at a target and gate on the per-RRPair verdict (status **and** body) against a known-good baseline, not on transport failures; catches status-code and field-level regressions that `requests.failed` misses | `proxymock replay --baseline --fail-on-new-mismatch` |
| [`proxymock-verify-fix`](proxymock-verify-fix/SKILL.md) | Prove a bug fix by replaying the incident capture at the fixed build; "recorded 500 -> observed 200" is the fix signal, any other new mismatch is collateral, and an all-match run means the bug still reproduces | `proxymock replay --verify-fix` |
| [`proxymock-perf-container`](proxymock-perf-container/SKILL.md) | Load-test one service with its downstream mocked, and judge the number honestly: when a level is harness-bound rather than app-bound, why cross-run rps comparison on a shared host is meaningless, and which figure survives a move to a sized container | `proxymock replay --vus --for --load-test` |
| [`proxymock-chaos-mock`](proxymock-chaos-mock/SKILL.md) | Inject faults into a mock with native fault flags so the downstream lies on demand: 503s, 429s with `Retry-After`, corrupt or truncated bodies, per-endpoint latency, socket-level connection faults, and exact deterministic ratios via `rate=F/N` | `proxymock mock --fault` |
| [`proxymock-contract-test`](proxymock-contract-test/SKILL.md) | Contract-test with traffic + OpenAPI: check recorded or replayed traffic against the dependency's spec with exact JSON-path violations, and mock a dependency straight from its spec before any recording exists | `proxymock validate` (plus `proxymock generate` for mock-from-spec) |
| [`proxymock-replay-tuning`](proxymock-replay-tuning/SKILL.md) | Replay outbound pairs against a local mock and report HIT/MISS/PASSTHROUGH so you can restore a stale mock set | `tune-proxymock-replay.sh` |
| [`quality-loop`](quality-loop/SKILL.md) | The entry point: route an intent to the right native command or analysis skill, with the one-time setup playbook, the blueprint rules, the shared gotcha catalog, and a `doctor` that checks the proxymock version, recordings, blueprints, and ports | builds and execs the native commands |

```shell
# check the environment, then route any intent through the quality loop
./skills/quality-loop/scripts/quality-loop.sh doctor

# one shared proof covers all five loop skills' exit-code contracts
./skills/quality-loop/scripts/prove-quality-loop.sh

# the five loop skills are one native command each -- run them directly, no bash needed
# regression gate: 0 pass, 3 new mismatch
proxymock replay --in lab/proxymock/recording --test-against http://localhost:8080 \
  --out ./regress-run --baseline ./regress-base --fail-on-new-mismatch

# prove a fix: 0 fixed, 2 bug still reproduces, 3 collateral
proxymock replay --in ./incident/recording --test-against http://localhost:8080 \
  --verify-fix --expect '^/api/stats'

# spec conformance: 0 conformant, 2 violations, 3 no spec route
proxymock validate --spec lab/openapi.yaml \
  --in lab/proxymock/recording/demo-api.trafficreplay.com

# make the mocked downstream fail exactly 1 request in 3
proxymock mock --in lab/proxymock/recording --fault '/v1/projects:status=503,rate=1/3'

# load: 0, or 1 when a --fail-if threshold trips
proxymock replay --in lab/proxymock/recording/localhost \
  --test-against http://localhost:8080 --vus 16 --for 30s --load-test

# the four analysis skills keep their own scripts
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in lab/proxymock/recording/localhost --test-against http://localhost:8080 --vus 8 --for 20s
./skills/proxymock-compare-results/scripts/proxymock-compare-results.sh \
  --in ./after --baseline ./before --drift --fail-on-regression
./skills/proxymock-summarize-recording/scripts/proxymock-summarize-recording.sh \
  --in lab/proxymock/recording --out recording-brief.md
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh --in lab/proxymock/recording
```

The Go app's opt-in telemetry beacon (`EMIT_TELEMETRY=1`) is the fixture for mock match-rate
tuning — rotating IDs, GraphQL, cursor pagination, sequenced polls, create→use, and auth/session.
See [go/README.md](../languages/go/README.md#run) and the
[mock match-rate tuning guide](https://docs.speedscale.com/proxymock/guides/mock-match-rate/).

## Traffic replay tuning

Traffic replay is useful because it keeps the story honest: the app succeeds or fails against
requests it already saw. In this lab, the story starts with the Go demo app calling the CNCF API
and running the auth/order flow. proxymock records that traffic as RRPairs. Then the mock set gets
stale — several downstream recordings are missing — and replay exposes the gap as `MISS` results.
Tuning means restoring or adjusting the mock set until the same replay passes cleanly.

Use [`proxymock-replay-tuning/`](proxymock-replay-tuning/SKILL.md) when a local
HTTP/HTTPS mock has replay misses and you need a repeatable match-rate report:

```shell
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh --in <recording-dir>
```

`--in` points at a recording; the script replays its outbound pairs against the mock and skips the
inbound ones. The committed recording works out of the box:

```shell
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh --in lab/proxymock/recording
```

To tune your own traffic from a fresh checkout, take a local recording. This example uses the Go
app, but the same pattern works from any language directory in this repo:

```shell
git clone https://github.com/speedscale/mock-lab.git
cd mock-lab/languages/go
proxymock record --out ../../replay-work/recording -- go run .
```

In another terminal from the repo root, drive the demo traffic, then tune the recording:

```shell
./lab/tests/run_tests.sh --recording
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh --in replay-work/recording
```

Or hand it to an AI agent from the repo root:

```text
Use the proxymock-replay-tuning skill to tune this replay.
Recording: replay-work/recording
Run the tuning script, summarize HIT/MISS/PASSTHROUGH, and recommend what transforms or recordings need to change.
```

The agent should run the tuning script, read `summary.json`, inspect misses in `mock-output/`, and
recommend concrete changes to recordings, signatures, filters, or transforms. Rerun the same skill
after each tuning change until the match rate is acceptable.

To verify the tuning workflow itself, run:

```shell
./skills/proxymock-replay-tuning/scripts/prove-proxymock-replay-tuning.sh
```

The proof tells the whole replay story: record real app traffic, create a stale mock baseline,
measure the misses, replay against the tuned mock set, and verify the hit rate improves.

## Works with your stack

The loop consumes recordings, not test frameworks, so most of your existing stack plugs in
as-is:

- **No bash required.** Each of the five loop skills is **one native `proxymock` command**
  taking a directory of RRPair files and a URL, and its exit code is the CI contract:
  `replay --fail-on-new-mismatch` exits 0/3, `replay --verify-fix` exits 0/2/3, `validate`
  exits 0/2/3, `replay --load-test --fail-if` exits 0/1. A k6, bruno, postman-cli, pytest,
  JUnit, or plain-Makefile user runs that line and gets the identical result. The
  `quality-loop.sh` dispatcher is optional convenience that builds the same line and passes
  the exit code through — the native command is the contract, and every SKILL.md leads with
  it.
- **Any test driver.** Whatever pushes traffic through the record proxy becomes the capture
  source: this repo's curl harness, your integration tests, Postman collections via
  [newman](https://www.npmjs.com/package/newman), k6 scripts, a staging soak, or live
  production capture with the Speedscale operator. Record once with
  `proxymock record -- <your app>` while your driver runs, and every command above works on
  the result.
- **Traffic captured elsewhere imports directly.** `proxymock import` converts GoReplay
  captures, HAR documents, raw HTTP wire dumps, Postman collections, and WireMock projects
  into RRPairs, so the loop does not require re-recording what you already have.
- **Any downstream mock, for the replay-based commands.** Regression, verify-fix, and load
  only need proxymock for record, replay, and diff; the thing mocking your dependencies is
  just an HTTP endpoint. If you already run WireMock or similar for downstreams, keep it.
- **proxymock-specific, by design:** `proxymock mock --fault` drives proxymock's own mock
  engine (timing control, deterministic `rate=F/N` rotation), and the replay verdict's
  per-pair body-change findings read RRPair data. The fault taxonomy and interpretation
  guidance in `proxymock-chaos-mock`'s SKILL.md port to any mock system; the mechanics do
  not.
- **Your traffic stays portable.** RRPairs are plain markdown files you can read, diff, and
  check in, and `proxymock export` converts recordings to WireMock stub mappings, Postman
  collections, k6 scripts, Gatling simulations, or Datadog Synthetics bundles if you need
  them elsewhere.
