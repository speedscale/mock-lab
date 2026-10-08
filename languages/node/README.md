# Node.js demo app

The Node.js version of the [mock-lab](../../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).
Zero dependencies — built-in `http` + global `fetch`. Needs **Node 24+** (or 22.21+) for the
built-in proxy support proxymock relies on; the devcontainer ships Node 24.

[Turn one recording into regression, contract, load and chaos scenarios](../../shared/SCENARIOS.md) with this app. The shared guide uses curl; the dashboard is optional.

## Run

```shell
node index.js
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
# Node's fetch ignores proxy env vars on its own. Turn on the built-in proxy support and
# trust proxymock's TLS CA — needed for both record and mock (not for replay):
export NODE_USE_ENV_PROXY=1
export NODE_EXTRA_CA_CERTS="$HOME/.speedscale/certs/tls.crt"

proxymock record -- node index.js                # 1. record the downstream calls
proxymock web                                    # 2. browse the recorded traffic (:7788)
proxymock mock -- node index.js                   # 3. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 4. replay (or use Replay in proxymock web)
```

Unlike the other languages, Node's `fetch` does not honor `http_proxy`/`https_proxy` by itself.
Node 24 (backported to 22.21) adds `NODE_USE_ENV_PROXY`, which routes `fetch` through proxymock;
`NODE_EXTRA_CA_CERTS` points Node at proxymock's CA so the recorded HTTPS call validates. On
older Node, route `fetch` through a proxy dispatcher per the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. Capture this flow with `../../shared/tests/run_tests.sh --recording` in a second terminal. The optional [dashboard](../../shared/README.md) also drives it and requires Go. On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see [`./proxymock/`](./proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../../README.md) and [`openapi.yaml`](../../shared/openapi.yaml).

## Committed workspace

This app's `proxymock/` directory includes its runtime-specific recording and the standard `applications/`, `blueprints/`, and `testconfigs/` companion documents. From this app directory, use the committed capture explicitly:

```shell
proxymock coverage --in proxymock/recording
proxymock replay --in proxymock/recording --test-against http://localhost:8080
```

Start the app under `proxymock mock --in proxymock/recording -- <app command>` in another terminal first; use the app command shown above. The blueprint chains fresh access tokens and order IDs. Coverage reports the happy-path calls and the missing error responses. New captures and replay results remain local and are ignored by git.
