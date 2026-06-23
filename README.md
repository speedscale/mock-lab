# mock-lab

Demo apps for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart — the same
small app in six languages. Each one calls a CNCF projects API as its downstream; proxymock
records that call, then mocks it so the app runs and tests with **no network**.

## Try it in GitHub Codespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/speedscale/mock-lab)

One click — all six runtimes and the `proxymock` CLI are preinstalled.

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

## proxymock quickstart

```shell
cd go                                          # pick any language dir (node/, python/, ...)
proxymock record -- go run .                   # record the app calling the downstream
./lab/tests/run_http_tests.sh --recording      # (new terminal, repo root) drive some traffic
proxymock mock -- go run .                      # mock the downstream — no network needed
proxymock replay --test-against http://localhost:8080
```

Go, Python, .NET, and C++ (via libcurl) honor proxy env vars natively; Node and Java need
the proxy config from the [language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

## The downstream API

The apps query a hosted CNCF projects API (default `demo-api-dev.trafficreplay.com`). You don't
run or manage it — its contract is in [`lab/openapi.yaml`](lab/openapi.yaml).

> Everything the lab needs for itself (the mock backend, the traffic driver, and the API spec)
> lives in [`lab/`](lab/). You can ignore it for the quickstart.
