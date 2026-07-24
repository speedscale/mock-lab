# mock-lab

Demo apps for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart — the same
small app in seven languages. Each one calls a CNCF projects API as its downstream; proxymock
records that call, then mocks it so the app runs and tests with **no network**.

## Try it in GitHub Codespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/speedscale/mock-lab)

One click — all seven runtimes and the `proxymock` CLI are preinstalled. Run
`proxymock init --api-key <key>` once to activate it (free key at
[app.speedscale.com/signup](https://app.speedscale.com/signup)).

## Pick your language

| Language | Run |
| --- | --- |
| [Go](go/README.md) | `cd go && go run .` |
| [Node.js](node/README.md) | `cd node && node index.js` |
| [Python](python/README.md) | `cd python && python3 app.py` |
| [Java](java/README.md) | `cd java && java App.java` |
| [Ruby](ruby/README.md) | `cd ruby && ruby app.rb` |
| [.NET](dotnet/README.md) | `cd dotnet && dotnet run` |
| [C++](cpp/README.md) | `cd cpp && c++ -std=c++17 main.cpp -o app -lcurl && ./app` |

Every app listens on `:8080` (override `PORT`) and calls the downstream at `DOWNSTREAM_URL`
(default `https://demo-api.trafficreplay.com`).

## Endpoints (identical across every language)

| Endpoint | Calls downstream | Returns |
| --- | --- | --- |
| `GET /` | – | service info |
| `GET /api/projects` | `/v1/projects` | all CNCF projects |
| `GET /api/projects/{id}` | `/v1/project/{id}` | one project |
| `GET /api/categories` | `/v1/categories` | categories with counts |
| `GET /api/stats` | `/v1/projects` | counts by maturity |
| `POST /oauth/token` | – | a fresh `access_token` |
| `POST /api/orders` ¹ | `/v1/project/{id}` | creates an order with a fresh `order_id` |
| `GET /api/orders/{order_id}` ¹ | – | the order |

¹ requires `Authorization: Bearer <access_token>`.

## proxymock quickstart

First time on a machine, [install proxymock](https://docs.speedscale.com/proxymock/) and activate it
once — `proxymock init --api-key <key>` (free key at
[app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is already
installed, so you only need the `init`.

```shell
cd go                                          # pick any language dir (node/, python/, ...)
proxymock record -- go run .                   # 1. record the app calling the downstream
./lab/tests/run_tests.sh --recording           # 2. new terminal (repo root): drive every endpoint
proxymock web                                   # 3. browse the recorded traffic in your browser (:7788)
proxymock mock -- go run .                      # 4. mock the downstream — no network needed
proxymock replay --test-against http://localhost:8080   # 5. replay it back at the app
```

One script drives the whole demo — the 5 read endpoints plus the OAuth + order flow — pausing ~1s
between calls so you can watch each one land in `proxymock web` (set `DELAY=0` to skip the pause).
Step 5 can also be run **from the proxymock web UI** instead of the `proxymock replay` command.

Go, Python, Ruby, Java, .NET, and C++ all work with `proxymock record` out of the box — proxymock
injects the proxy and TLS settings each runtime understands (for Java, via `JAVA_TOOL_OPTIONS`).
**Node is the exception:** its `fetch` ignores proxy env vars until Node 24 (backported to 22.21),
so set `NODE_USE_ENV_PROXY=1` and `NODE_EXTRA_CA_CERTS` first — see [node/README.md](node/README.md).

## Auth handshake + the two moving IDs

Each app also exposes a small OAuth-style flow, built to show how proxymock handles values that
change between record and replay. `POST /oauth/token` returns a fresh `access_token`;
`POST /api/orders` (Bearer-protected, validates the project against the downstream) returns a
fresh `order_id`; `GET /api/orders/{order_id}` (Bearer-protected) reads it back. Those two IDs
are **regenerated on every call**, so on replay the recorded token/order_id are stale and the
protected calls would 401/404 — until *smart replace* chains them.

A committed recording **and** smart-replace blueprint ship in [`lab/proxymock/`](lab/proxymock/),
so you can mock + replay the whole demo (basic + auth endpoints) **offline against any language**,
with no recording step:

```shell
cd go                                                          # any language dir
proxymock mock --in ../lab/proxymock/recording -- go run .     # downstream served from the recording
# in another terminal:
proxymock replay --in ../lab/proxymock/recording --test-against http://localhost:8080
```

Replay passes 0% failed — the blueprint (`res_body → json_path → smart_replace_recorded` on
`access_token` and `order_id`) re-chains both IDs. To record your own and watch it happen, use the
quickstart above (`./lab/tests/run_tests.sh --recording` drives the auth flow too).

## Mock match-rate tuning (MCP)

The Go app has an opt-in telemetry beacon (`EMIT_TELEMETRY=1`) whose outbound calls each
rotate on every run, so a replay produces mock misses by construction and exercises the
tuner's pattern discovery: rotating UUIDs, a full set of **time-anchored ids** (ULID, epoch,
Snowflake, Mongo ObjectId, UUIDv7, xid, KSUID), a **GraphQL** operation (variable masked,
`query`/`operationName` protected), a **cursor pagination** flow whose value flows
response→request (a correlation to bind, surfaced by `POST /api/mocks/provenance`), a
**stateful poll** (same request, cycling response → needs a sequenced mock) with a companion
**noise-only** endpoint (differs solely in a rotating timestamp), a **create→use** id
(`POST /v1/orders` → `GET /v1/orders/{id}` — bound, never wildcarded), and an **auth/session**
flow (token + session cookie replayed in headers → surfaced as credentials to correlate). The
cursor, poll, create→use, and auth flows need the lab reference server as downstream
(`DOWNSTREAM_URL=http://localhost:8090` against `../lab/server`). See
[`go/README.md`](go/README.md#run) for the per-call breakdown. The
[mock match-rate tuning guide](https://docs.speedscale.com/proxymock/guides/mock-match-rate/)
uses it to demonstrate the `improve-mock-match-rate` skill and the proxymock MCP tuning tools
(`analyze_mock_matches`, `accept_mock_recommendation`, `similar_candidates`): record with the
beacon on, mock + replay, then let an AI agent tune the blueprint until the match rate is 100%.

## Traffic replay tuning

Traffic replay is useful because it keeps the story honest: the app succeeds or fails against
requests it already saw. In this lab, the story starts with the Go demo app calling the CNCF API
and running the auth/order flow. proxymock records that traffic as RRPairs. Then the mock set gets
stale — several downstream recordings are missing — and replay exposes the gap as `MISS` results.
Tuning means restoring or adjusting the mock set until the same replay passes cleanly.

Use [`skills/proxymock-replay-tuning/`](skills/proxymock-replay-tuning/SKILL.md) when a local
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
cd mock-lab/go
proxymock record --out ../replay-work/recording -- go run .
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

## More proxymock skills

The same recordings power nine more agent skills in [`skills/`](skills/). Each ships a script and
a `prove-*.sh`, runs against the committed `lab/proxymock/recording`, and needs no Speedscale Cloud
account. Shared bash helpers for the skill scripts live in
[`skills/lib/common.sh`](skills/lib/common.sh). Not sure which one applies? Start with
[`quality-loop`](skills/quality-loop/SKILL.md): it routes an intent to the right skill and its
`doctor` checks the environment.

| Skill | What it does | Wraps |
| --- | --- | --- |
| [`proxymock-load-test`](skills/proxymock-load-test/SKILL.md) | Replay recorded traffic at a target with parallel virtual users; report latency percentiles, throughput, and match rate, with `--fail-if` SLO gates | `proxymock replay --vus --for --fail-if` |
| [`proxymock-compare-results`](skills/proxymock-compare-results/SKILL.md) | Deep before/after comparison of two replay/recording sets — what regressed, improved, or persisted across performance/reliability/security; writes JSON, HTML, and an LLM digest | `proxymock report --baseline` + `proxymock drift` |
| [`proxymock-summarize-recording`](skills/proxymock-summarize-recording/SKILL.md) | Summarize a recording: hosts, inbound/outbound endpoints, methods, status mix, volume, plus the report digest | `proxymock report --format prompt` |
| [`proxymock-regression-test`](skills/proxymock-regression-test/SKILL.md) | Replay a recording at a target and gate on per-RRPair result-match tags and budget flips, not transport failures; catches status-code regressions that `requests.failed` misses | `proxymock replay` + `proxymock report --baseline` |
| [`proxymock-verify-fix`](skills/proxymock-verify-fix/SKILL.md) | Prove a bug fix by replaying the incident capture at the fixed build; "recorded 500 -> observed 200" is the fix signal, any other new mismatch is collateral, and an all-match run means the bug still reproduces | `proxymock replay` |
| [`proxymock-perf-container`](skills/proxymock-perf-container/SKILL.md) | Load-test one service with its downstream mocked: walk a VU ladder to the throughput knee, gate rps/p99 budgets there with margins, and refuse to report harness saturation as an app limit (per-level CPU attribution) | `proxymock replay --vus` via `proxymock-load-test` |
| [`proxymock-chaos-mock`](skills/proxymock-chaos-mock/SKILL.md) | Inject faults into a mock by editing a copy of the recording so the downstream lies on demand: latency, 503s, 429s with `Retry-After`, garbage bodies, and exact deterministic flaky ratios via duplicate-signature round-robin | RRPair edits on a copy + `proxymock mock --mock-timing` |
| [`proxymock-contract-test`](skills/proxymock-contract-test/SKILL.md) | Contract-test with traffic + OpenAPI: mock a dependency straight from its spec before any recording exists, and validate recorded/replayed responses against the spec with exact JSON-path violations (proxymock has no native traffic-vs-spec check, so the skill bundles one) | `proxymock generate` + `proxymock mock` + bundled schema checker |
| [`quality-loop`](skills/quality-loop/SKILL.md) | The entry point: route an intent (regression gate, fix verification, capacity, chaos, contract, comparison, summary, tuning, load) to the right skill above, with the one-time setup playbook, the shared gotcha catalog, and a `doctor` that checks proxymock, recordings, blueprints, and ports | dispatches the sibling skill scripts |

```shell
# check the environment, then route any intent through the quality loop
./skills/quality-loop/scripts/quality-loop.sh doctor
./skills/quality-loop/scripts/quality-loop.sh regression --in lab/proxymock/recording \
  --test-against http://localhost:8080

# quick load test against the mocked app (run `cd go && proxymock mock --in ../lab/proxymock/recording -- go run .` first)
./skills/proxymock-load-test/scripts/proxymock-load-test.sh \
  --in lab/proxymock/recording/localhost --test-against http://localhost:8080 --vus 8 --for 20s

# deep comparison of two replay outputs
./skills/proxymock-compare-results/scripts/proxymock-compare-results.sh \
  --in ./after --baseline ./before --drift --fail-on-regression

# summarize what a recording contains
./skills/proxymock-summarize-recording/scripts/proxymock-summarize-recording.sh \
  --in lab/proxymock/recording --out recording-brief.md

# regression-test a change against a known-good replay
./skills/proxymock-regression-test/scripts/proxymock-regression-test.sh \
  --in lab/proxymock/recording --test-against http://localhost:8080 \
  --baseline ./regress-base/replayed --fail-on-regression

# verify a bug fix by replaying the incident capture at the fixed build
./skills/proxymock-verify-fix/scripts/proxymock-verify-fix.sh \
  --in ./incident/recording --test-against http://localhost:8080 \
  --expect '^/api/stats' --baseline ./reproduce-work/run-1/replayed

# find what one container can sustain and gate a perf budget at the knee
./skills/proxymock-perf-container/scripts/proxymock-perf-container.sh \
  --in lab/proxymock/recording/localhost --test-against http://localhost:8080 \
  --assert-rps 2000 --assert-p99 50ms

# make the mocked downstream fail exactly 1 request in 3 and serve the lying mock
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --in lab/proxymock/recording --scenario flaky --target '^/v1/projects' \
  --ratio 1/3 --serve

# check the recorded downstream traffic against its OpenAPI spec
./skills/proxymock-contract-test/scripts/proxymock-contract-test.sh conformance \
  --spec lab/openapi.yaml --in lab/proxymock/recording/demo-api.trafficreplay.com
```

## Works with your stack

The skills consume recordings, not test frameworks, so most of your existing stack plugs in
as-is:

- **Any test driver.** Whatever pushes traffic through the record proxy becomes the capture
  source: this repo's curl harness, your integration tests, Postman collections via
  [newman](https://www.npmjs.com/package/newman), k6 scripts, a staging soak, or live
  production capture with the Speedscale operator. Record once with
  `proxymock record -- <your app>` while your driver runs, and every skill above works on
  the result.
- **Traffic captured elsewhere imports directly.** `proxymock import` converts GoReplay
  captures, HAR documents, raw HTTP wire dumps, Postman collections, and WireMock projects
  into RRPairs, so the loop does not require re-recording what you already have.
- **Any downstream mock, for the replay-based skills.** `proxymock-regression-test`,
  `proxymock-verify-fix`, and `proxymock-perf-container` only need proxymock for record,
  replay, and diff; the thing mocking your dependencies is just an HTTP endpoint. If you
  already run WireMock or similar for downstreams, keep it.
- **proxymock-specific, by design:** `proxymock-chaos-mock` drives proxymock's mock engine
  directly (timing control, deterministic duplicate-signature rotation), and the replay
  match tags and `response_diff` verdicts all read RRPair data. The fault scenarios and
  interpretation guidance in its SKILL.md port to any mock system; the mechanics do not.
- **Your traffic stays portable.** RRPairs are plain markdown files you can read, diff, and
  check in, and `proxymock export` converts recordings to WireMock stub mappings, Postman
  collections, k6 scripts, Gatling simulations, or Datadog Synthetics bundles if you need
  them elsewhere.

## The downstream API

The apps query a hosted CNCF projects API (default `demo-api.trafficreplay.com`). You don't
run or manage it — its contract is in [`lab/openapi.yaml`](lab/openapi.yaml).

> Everything the lab needs for itself (the mock backend, the traffic driver, and the API spec)
> lives in [`lab/`](lab/). You can ignore it for the quickstart.
