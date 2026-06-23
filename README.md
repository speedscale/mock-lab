# mock-lab

A tiny, multi-language demo for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart.

Each app exposes a small HTTP API and fulfills requests by calling a **CNCF projects API**
downstream at `https://demo-api.trafficreplay.com`. proxymock records those downstream
calls, then mocks them so the app runs and tests with **no network and no dependencies of
its own** — the downstream is a static, Speedscale-owned endpoint that can't be
rate-limited or archived.

## Pick your language

| Language | Run |
| --- | --- |
| Go | `go run main.go` |
| Node.js | `node node/index.js` |
| Python | `python3 python/app.py` |
| Java | `java java/App.java` |
| Ruby | `ruby ruby/app.rb` |
| .NET | `cd dotnet && dotnet run` |

Every app listens on `:8080` (override `PORT`) and calls `DOWNSTREAM_URL`
(default `https://demo-api.trafficreplay.com`).

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
proxymock record -- go run main.go            # record the app calling the live downstream
./tests/run_http_tests.sh --recording         # drive some traffic
proxymock mock -- go run main.go              # mock the downstream — no network needed
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
go run ./server                  # serve the CNCF API locally on :8090
go run ./server -export ./static # render the static file tree (for S3)
```

Routes: `GET /v1/projects`, `GET /v1/project/{id}`, `GET /v1/categories`,
`GET /v1/maturity/{graduated|incubating|sandbox}`, `GET /healthz`.

> The data in `server/data/projects.json` is a frozen snapshot of the CNCF landscape for
> demo purposes and may not reflect a project's current maturity or star count.

## Run it all locally (no AWS)

`./run-local.sh` renders the dataset, serves it the way CloudFront/S3 will, runs the Go app
against it, and smoke-tests — all on auto-picked free ports.
