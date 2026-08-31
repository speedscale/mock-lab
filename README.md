# mock-lab

Demo apps for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart — the same
small app in seven languages. Each one calls a CNCF projects API as its downstream; proxymock
records that call, then mocks it so the app runs and tests with **no network**.

This repo also holds [other labs](#other-labs) and
[agent skills](skills/README.md) that reuse the same recordings.

## Try it in GitHub Codespaces

[![Open in GitHub Codespaces](.github/codespaces-badge.svg)](https://codespaces.new/speedscale/mock-lab)

One click — all seven runtimes and the `proxymock` CLI are preinstalled. Run
`proxymock init --api-key <key>` once to activate it (free key at
[app.speedscale.com/signup](https://app.speedscale.com/signup)).

## Pick your language

| Language | Run | Its own recording |
| --- | --- | --- |
| [Go](languages/go/README.md) | `cd languages/go && go run .` | [`languages/go/proxymock/recording`](languages/go/proxymock/recording) |
| [Node.js](languages/node/README.md) | `cd languages/node && node index.js` | [`languages/node/proxymock/recording`](languages/node/proxymock/recording) |
| [Python](languages/python/README.md) | `cd languages/python && python3 app.py` | [`languages/python/proxymock/recording`](languages/python/proxymock/recording) |
| [Java](languages/java/README.md) | `cd languages/java && java App.java` | [`languages/java/proxymock/recording`](languages/java/proxymock/recording) |
| [Ruby](languages/ruby/README.md) | `cd languages/ruby && ruby app.rb` | [`languages/ruby/proxymock/recording`](languages/ruby/proxymock/recording) |
| [.NET](languages/dotnet/README.md) | `cd languages/dotnet && dotnet run` | [`languages/dotnet/proxymock/recording`](languages/dotnet/proxymock/recording) |
| [C++](languages/cpp/README.md) | `cd languages/cpp && c++ -std=c++17 main.cpp -o app -lcurl && ./app` | [`languages/cpp/proxymock/recording`](languages/cpp/proxymock/recording) |

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
cd languages/go                                # pick any language dir (languages/node/, ...)
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
so set `NODE_USE_ENV_PROXY=1` and `NODE_EXTRA_CA_CERTS` first — see [languages/node/README.md](languages/node/README.md).

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
cd languages/go                                                # any language dir
proxymock mock --in ../../lab/proxymock/recording -- go run .  # downstream served from the recording
# in another terminal:
proxymock replay --in ../../lab/proxymock/recording --test-against http://localhost:8080
```

Replay passes 0% failed — the blueprint (`res_body → json_path → smart_replace_recorded` on
`access_token` and `order_id`) re-chains both IDs. To record your own and watch it happen, use the
quickstart above (`./lab/tests/run_tests.sh --recording` drives the auth flow too).

## Two kinds of committed recording

There are two, and they answer different questions.

[`lab/proxymock/recording`](lab/proxymock/recording) is the **shared cross-language fixture**. It ships with the smart-replace blueprint, replays 0% failed against *any* of the seven apps, and is what the [`skills/`](skills/) proof scripts run against. Use it when the language does not matter and you want the auth flow to chain cleanly.

`languages/<lang>/proxymock/recording` is the **per-runtime one**: one recording per language, each captured from that language's own server. Use it when you care how a specific runtime actually behaves on the wire. Every language dir has one, so `proxymock/` next to the app is also the layout you get from a plain `proxymock record` in that directory. That is the convention, not a special case.

Each per-language recording holds 13 RRPairs: 8 inbound under `localhost/` (the app's own API) and 5 outbound under `demo-api.trafficreplay.com/` (the CNCF downstream). To mock + replay a language against its own capture:

```shell
cd languages/ruby                                          # any language dir
proxymock mock --in ./proxymock/recording -- ruby app.rb   # downstream served from ruby's own recording
# in another terminal:
proxymock replay --in ./proxymock/recording --test-against http://localhost:8080
```

Use `localhost`, not `127.0.0.1`, because the recorded signature keys on the host as written. Replay reports 8 requests, 0% failed, 25% status-code mismatch: the two Bearer-protected endpoints (`POST /api/orders` and `GET /api/orders/{order_id}`) 401 because the recorded `access_token` is stale and no blueprint is staged in the language dir. That is expected. For a clean 0%, use the `lab/` fixture and its blueprint above.

[`lab/vendor-capture`](lab/vendor-capture) is a drifted copy of the same five downstream pairs, used by the contract-test skill. See [`lab/README.md`](lab/README.md#vendor-capture) for what was edited and how `proxymock validate` behaves against it.

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

The Go app also has an opt-in telemetry beacon (`EMIT_TELEMETRY=1`) for mock match-rate tuning — see [languages/go/README.md](languages/go/README.md#run).

## Other labs

Each lab is its own subdirectory. They are not the seven-language demo; they pair proxymock
with a specific tool so an agent can diagnose a planted issue from real evidence.

| Lab | What it demonstrates |
| --- | --- |
| [pyroscope](pyroscope/README.md) | CPU profile + proxymock replay to find a bottleneck, prove the response did not change, and measure again |
| [prometheus](prometheus/README.md) | p95 latency from connection queueing, not CPU |
| [tempo](tempo/README.md) | a serial dependency waterfall made visible in traces |
| [loki](loki/README.md) | a rare retry path that never fails the response contract — evidence is only in the logs |
| [hubble](hubble/README.md) | a request timeout caused by a Cilium network policy, not the application |
| [obi](obi/README.md) | eBPF instrumentation of an opaque service with no OpenTelemetry SDK |
| [chaos](chaos/README.md) | a scoped chaos rule that forces the storefront's unused inventory-fallback path to run |

## Agent skills

[`skills/`](skills/README.md) is the proxymock agent-skills pack: regression, verify-fix, chaos,
contract testing, load, replay tuning, and more. They run against `lab/proxymock/recording` and
need no Speedscale Cloud account. Start with [`quality-loop`](skills/quality-loop/SKILL.md).

## The downstream API

The apps query a hosted CNCF projects API (default `demo-api.trafficreplay.com`). You don't
run or manage it — its contract is in [`lab/openapi.yaml`](lab/openapi.yaml).

> Everything the lab needs for itself (the mock backend, the traffic driver, and the API spec)
> lives in [`lab/`](lab/). You can ignore it for the quickstart.
