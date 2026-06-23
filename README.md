# mock-lab

A tiny, multi-language demo for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart.

Each app exposes a small HTTP API and fulfills requests by calling a **CNCF projects API**
downstream at `https://demo-api-dev.trafficreplay.com`. proxymock records those downstream
calls, then mocks them so the app runs and tests with **no network and no dependencies of
its own** — the downstream is a static, Speedscale-owned endpoint that can't be
rate-limited or archived.

## Try it in GitHub Codespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/speedscale/mock-lab)

One click — Go, Node, Python, Java, Ruby, .NET, and the `proxymock` CLI are all preinstalled.

## Pick your language

| Language | Run |
| --- | --- |
| Go | `cd go && go run .` |
| Node.js | `cd node && node index.js` |
| Python | `cd python && python3 app.py` |
| Java | `cd java && java App.java` |
| Ruby | `cd ruby && ruby app.rb` |
| .NET | `cd dotnet && dotnet run` |

Every app listens on `:8080` (override `PORT`) and calls `DOWNSTREAM_URL`
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
proxymock record -- go run .                   # record the app calling the live downstream
./tests/run_http_tests.sh --recording          # (new terminal, repo root) drive some traffic
proxymock mock -- go run .                      # mock the downstream — no network needed
proxymock replay --test-against http://localhost:8080
```

Use the run command for your language. Go, Python, and .NET honor proxy env vars
natively; Node and Java need the proxy config from the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

## The downstream

`server/` is the reference implementation of `demo-api.trafficreplay.com`. The quickstart
user never runs it — it documents the contract and generates the static dataset that is
deployed to S3 behind CloudFront.

```shell
cd server && go run .                   # serve the CNCF API locally on :8090
cd server && go run . -export ../static # render the static file tree (for S3)
```

Routes: `GET /v1/projects`, `GET /v1/project/{id}`, `GET /v1/categories`,
`GET /v1/maturity/{graduated|incubating|sandbox}`, `GET /healthz`.

> The data in `server/data/projects.json` is a frozen snapshot of the CNCF landscape for
> demo purposes and may not reflect a project's current maturity or star count.

## Run it all locally (no cloud)

`./run-local.sh` renders the dataset, serves it the way CloudFront/S3 will, runs the Go app
against it, and smoke-tests — all on auto-picked free ports.
