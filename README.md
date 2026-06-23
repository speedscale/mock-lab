# mock-lab

Demo apps for the [proxymock](https://docs.speedscale.com/proxymock/) quickstart — the same
small app in six languages. Each one calls a **CNCF projects API** as its downstream;
proxymock records that call, then mocks it so the app runs and tests with **no network**.

## What's in this repo

Two independent parts — **most people only need Part 1:**

| Part | Directories | What it is |
| --- | --- | --- |
| **1. Demo apps** | `go/` `node/` `python/` `java/` `ruby/` `dotnet/` | **What you run.** The quickstart sample app, one per language. |
| **2. Downstream API** | `server/` | Source of the **already-hosted** API at `demo-api.trafficreplay.com` that the apps call. Reference only — **you don't run this.** |

---

# Part 1 — the demo apps (run these)

## Try it in GitHub Codespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/speedscale/mock-lab)

One click — all six runtimes and the `proxymock` CLI are preinstalled.

## Pick your language

| Language | Run |
| --- | --- |
| Go | `cd go && go run .` |
| Node.js | `cd node && node index.js` |
| Python | `cd python && python3 app.py` |
| Java | `cd java && java App.java` |
| Ruby | `cd ruby && ruby app.rb` |
| .NET | `cd dotnet && dotnet run` |

Every app listens on `:8080` (override `PORT`) and calls the hosted downstream at
`DOWNSTREAM_URL` (default `https://demo-api-dev.trafficreplay.com`).

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

Use the run command for your language. Go, Python, and .NET honor proxy env vars natively;
Node and Java need the proxy config from the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

---

# Part 2 — the downstream API (reference only)

`server/` is the source for **`demo-api.trafficreplay.com`** — a static CNCF dataset served
from S3 behind CloudFront. **The quickstart never runs this**; it lives here so you can see
the contract and regenerate the dataset. Run it only if you want a fully local downstream:

```shell
cd server && go run .                   # serve the CNCF API locally on :8090
cd server && go run . -export ../static # render the static file tree (for S3)
```

Routes: `GET /v1/projects`, `GET /v1/project/{id}`, `GET /v1/categories`,
`GET /v1/maturity/{graduated|incubating|sandbox}`, `GET /healthz`.

> The data in `server/data/projects.json` is a frozen snapshot of the CNCF landscape for
> demo purposes and may not reflect a project's current maturity or star count.

## Run fully offline (no cloud)

Want Part 1 + Part 2 wired together with no internet? `./run-local.sh` renders the dataset,
serves it the way CloudFront/S3 will, runs the Go app against it, and smoke-tests — all on
auto-picked free ports.
