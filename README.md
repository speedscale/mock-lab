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
(default `https://demo-api-dev.trafficreplay.com`).

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

```shell
cd go                                          # pick any language dir (node/, python/, ...)
proxymock record -- go run .                   # record the app calling the downstream
./lab/tests/run_http_tests.sh --recording      # (new terminal, repo root) drive some traffic
proxymock mock -- go run .                      # mock the downstream — no network needed
proxymock replay --test-against http://localhost:8080
```

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
`access_token` and `order_id`) re-chains both IDs. To record your own and watch it happen:
`proxymock record -- go run .`, then `./lab/tests/run_auth_tests.sh --recording`.

## Traffic replay tuning

Traffic replay is useful because it keeps the story honest: the app succeeds or fails against
requests it already saw. In this lab, the story starts with the Go demo app calling the CNCF API
and running the auth/order flow. proxymock records that traffic as RRPairs. Then the mock set gets
stale — several downstream recordings are missing — and replay exposes the gap as `MISS` results.
Tuning means restoring or adjusting the mock set until the same replay passes cleanly.

Use [`skills/proxymock-replay-tuning/`](skills/proxymock-replay-tuning/SKILL.md) when a local
HTTP/HTTPS mock has replay misses and you need a repeatable match-rate report:

```shell
./skills/proxymock-replay-tuning/scripts/tune-proxymock-replay.sh \
  --mock-in <candidate-mock-dir> \
  --replay-in <replay-dir>
```

To verify the tuning workflow itself, run:

```shell
./skills/proxymock-replay-tuning/scripts/prove-proxymock-replay-tuning.sh
```

The proof tells the whole replay story: record real app traffic, create a stale mock baseline,
measure the misses, replay against the tuned mock set, and verify the hit rate improves.

## The downstream API

The apps query a hosted CNCF projects API (default `demo-api-dev.trafficreplay.com`). You don't
run or manage it — its contract is in [`lab/openapi.yaml`](lab/openapi.yaml).

> Everything the lab needs for itself (the mock backend, the traffic driver, and the API spec)
> lives in [`lab/`](lab/). You can ignore it for the quickstart.
