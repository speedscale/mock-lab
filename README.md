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

| Language | Run | Its own recording |
| --- | --- | --- |
| [Go](go/README.md) | `cd go && go run .` | [`go/proxymock/recording`](go/proxymock/recording) |
| [Node.js](node/README.md) | `cd node && node index.js` | [`node/proxymock/recording`](node/proxymock/recording) |
| [Python](python/README.md) | `cd python && python3 app.py` | [`python/proxymock/recording`](python/proxymock/recording) |
| [Java](java/README.md) | `cd java && java App.java` | [`java/proxymock/recording`](java/proxymock/recording) |
| [Ruby](ruby/README.md) | `cd ruby && ruby app.rb` | [`ruby/proxymock/recording`](ruby/proxymock/recording) |
| [.NET](dotnet/README.md) | `cd dotnet && dotnet run` | [`dotnet/proxymock/recording`](dotnet/proxymock/recording) |
| [C++](cpp/README.md) | `cd cpp && c++ -std=c++17 main.cpp -o app -lcurl && ./app` | [`cpp/proxymock/recording`](cpp/proxymock/recording) |

Every app listens on `:8080` (override `PORT`) and calls the downstream at `DOWNSTREAM_URL`
(default `https://demo-api.trafficreplay.com`).

## Profiling + replay agent lab

[`pyroscope/`](pyroscope/README.md) is a separate Go performance-debugging lab. It combines a
Grafana Pyroscope CPU profile with deterministic proxymock traffic so an AI coding agent can locate
a bottleneck, optimize it, prove the response did not change, and measure the same workload again.

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

## Two kinds of committed recording

There are two, and they answer different questions.

[`lab/proxymock/recording`](lab/proxymock/recording) is the **shared cross-language fixture**. It ships with the smart-replace blueprint, replays 0% failed against *any* of the seven apps, and is what the [`skills/`](skills/) proof scripts run against. Use it when the language does not matter and you want the auth flow to chain cleanly.

`<lang>/proxymock/recording` is the **per-runtime one**: one recording per language, each captured from that language's own server. Use it when you care how a specific runtime actually behaves on the wire. Every language dir has one, so `proxymock/` next to the app is also the layout you get from a plain `proxymock record` in that directory. That is the convention, not a special case.

Each per-language recording holds 13 RRPairs: 8 inbound under `localhost/` (the app's own API) and 5 outbound under `demo-api.trafficreplay.com/` (the CNCF downstream). To mock + replay a language against its own capture:

```shell
cd ruby                                                    # any language dir
proxymock mock --in ./proxymock/recording -- ruby app.rb   # downstream served from ruby's own recording
# in another terminal:
proxymock replay --in ./proxymock/recording --test-against http://localhost:8080
```

Use `localhost`, not `127.0.0.1`, because the recorded signature keys on the host as written. Replay reports 8 requests, 0% failed, 25% status-code mismatch: the two Bearer-protected endpoints (`POST /api/orders` and `GET /api/orders/{order_id}`) 401 because the recorded `access_token` is stale and no blueprint is staged in the language dir. That is expected. For a clean 0%, use the `lab/` fixture and its blueprint above.

There is also [`lab/vendor-capture`](lab/vendor-capture), which is not a third kind of recording but a deliberately drifted copy of the same five downstream pairs, standing in for a capture taken after the vendor shipped an API update. Two responses were edited to break [`lab/openapi.yaml`](lab/openapi.yaml): one `GET /v1/categories` element reports `count` as a string, and one of the two `GET /v1/project/kubernetes` pairs drops the required `maturity` field while the other keeps it, so the capture contradicts itself on the same endpoint minutes apart. It exists to demo contract testing — `proxymock validate --spec lab/openapi.yaml --in lab/vendor-capture/demo-api.trafficreplay.com` exits 2 with 3 conformant and 2 violating, while the same command against `lab/proxymock/recording/demo-api.trafficreplay.com` still exits 0 with 5 conformant. `lab/proxymock/recording` remains the clean one and is what every skill proof and replay example uses; nothing mocks or replays the vendor capture.

### What actually differs between runtimes

The seven apps serve identical endpoints with identical JSON, so the interesting difference is what each HTTP server adds on its own. Measured from the committed recordings, `GET /` on each:

| Language | Server implementation | Response headers recorded | `Server` banner | `Content-Type` |
| --- | --- | --- | --- | --- |
| Go | `net/http` | `Content-Type`, `Date` | none | `application/json` |
| Node.js | `node:http` | `Connection`, `Content-Type`, `Date`, `Keep-Alive` | none | `application/json` |
| Python | `http.server` | `Content-Type`, `Date`, `Server` | `BaseHTTP/0.6 Python/3.14.6` | `application/json` |
| Java | `com.sun.net.httpserver` | `Content-Type`, `Date` | none | `application/json` |
| Ruby | raw `TCPServer` | `Content-Type` | none | `application/json` |
| .NET | Kestrel | `Content-Type`, `Date`, `Server` | `Kestrel` | `application/json; charset=utf-8` |
| C++ | raw POSIX sockets | `Content-Type` | none | `application/json` |

Three things fall out of that table. Only **Python and .NET announce themselves** with a `Server` header, and .NET's is the bare product name while Python's carries both the handler and the interpreter version, so a Python recording pins the patch release it was captured on. **Ruby and C++ emit neither `Date` nor `Server`**, because both hand-write the status line and headers into the socket rather than going through a server library; a library adds `Date` for you, a `printf` does not. And **.NET is the only one that appends `charset=utf-8`** to `Content-Type`, which matters because a strict content-type assertion tuned on one runtime will fail on Kestrel.

Node is the only runtime that records connection-management headers (`Connection: keep-alive` plus `Keep-Alive: timeout=5`).

Two things that are **not** differences, worth stating because they look like they should be. Status lines are identical everywhere (`200 OK` and `201 Created`, same spelling, same casing), and `Date`, wherever present, is the same RFC 7231 IMF-fixdate format. Header ordering and message framing are **not observable** from an RRPair at all: proxymock stores headers alphabetically, and no `Content-Length` or `Transfer-Encoding` survives capture in any recording here, including the outbound ones from the real remote server. Ruby and C++ both write a `Content-Length` that the recording does not keep. So do not use these files to reason about framing.

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

The same recordings power nine more agent skills in [`skills/`](skills/). All of them run against
the committed `lab/proxymock/recording` and need no Speedscale Cloud account. Not sure which one
applies? Start with [`quality-loop`](skills/quality-loop/SKILL.md): it routes an intent to the
right command and its `doctor` checks the environment.

**The five loop skills are documentation over native commands.** `proxymock` does the work
itself now, so each of those SKILL.md files shows the raw CLI line and its exit codes, and the
single [`quality-loop.sh`](skills/quality-loop/scripts/quality-loop.sh) dispatcher just builds
that line, execs it, and passes the exit code through. Nothing re-derives a verdict. The four
analysis skills (load-test, compare-results, summarize-recording, replay-tuning) keep their own
scripts and proofs.

**These skills assume proxymock v2.5.814 or newer.** Their guidance was measured on that
release, and older builds differ on connection faults, native body scoring,
`--require-blueprint`, `proxymock validate`, and process teardown.
`./skills/quality-loop/scripts/quality-loop.sh doctor` warns if the installed CLI is older.

| Skill | What it does | Wraps |
| --- | --- | --- |
| [`proxymock-load-test`](skills/proxymock-load-test/SKILL.md) | Replay recorded traffic at a target with parallel virtual users; report latency percentiles, throughput, and match rate, with `--fail-if` SLO gates | `proxymock replay --vus --for --fail-if` |
| [`proxymock-compare-results`](skills/proxymock-compare-results/SKILL.md) | Deep before/after comparison of two replay/recording sets — what regressed, improved, or persisted across performance/reliability/security; writes JSON, HTML, and an LLM digest | `proxymock report --baseline` + `proxymock drift` |
| [`proxymock-summarize-recording`](skills/proxymock-summarize-recording/SKILL.md) | Summarize a recording: hosts, inbound/outbound endpoints, methods, status mix, volume, plus the report digest | `proxymock report --format prompt` |
| [`proxymock-regression-test`](skills/proxymock-regression-test/SKILL.md) | Replay a recording at a target and gate on the per-RRPair verdict (status **and** body) against a known-good baseline, not on transport failures; catches status-code and field-level regressions that `requests.failed` misses | `proxymock replay --baseline --fail-on-new-mismatch` |
| [`proxymock-verify-fix`](skills/proxymock-verify-fix/SKILL.md) | Prove a bug fix by replaying the incident capture at the fixed build; "recorded 500 -> observed 200" is the fix signal, any other new mismatch is collateral, and an all-match run means the bug still reproduces | `proxymock replay --verify-fix` |
| [`proxymock-perf-container`](skills/proxymock-perf-container/SKILL.md) | Load-test one service with its downstream mocked, and judge the number honestly: when a level is harness-bound rather than app-bound, why cross-run rps comparison on a shared host is meaningless, and which figure survives a move to a sized container | `proxymock replay --vus --for --load-test` |
| [`proxymock-chaos-mock`](skills/proxymock-chaos-mock/SKILL.md) | Inject faults into a mock with native fault flags so the downstream lies on demand: 503s, 429s with `Retry-After`, corrupt or truncated bodies, per-endpoint latency, socket-level connection faults, and exact deterministic ratios via `rate=F/N` | `proxymock mock --fault` |
| [`proxymock-contract-test`](skills/proxymock-contract-test/SKILL.md) | Contract-test with traffic + OpenAPI: check recorded or replayed traffic against the dependency's spec with exact JSON-path violations, and mock a dependency straight from its spec before any recording exists | `proxymock validate` (plus `proxymock generate` for mock-from-spec) |
| [`quality-loop`](skills/quality-loop/SKILL.md) | The entry point: route an intent to the right native command or analysis skill, with the one-time setup playbook, the blueprint rules, the shared gotcha catalog, and a `doctor` that checks the proxymock version, recordings, blueprints, and ports | builds and execs the native commands |

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

## The downstream API

The apps query a hosted CNCF projects API (default `demo-api.trafficreplay.com`). You don't
run or manage it — its contract is in [`lab/openapi.yaml`](lab/openapi.yaml).

> Everything the lab needs for itself (the mock backend, the traffic driver, and the API spec)
> lives in [`lab/`](lab/). You can ignore it for the quickstart.
