# .NET demo app

The .NET version of the [mock-lab](../../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).

## Run

```shell
dotnet run
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
proxymock record -- dotnet run                   # 1. record the downstream calls
cd ../../shared/dashboard && go run .               # 2. second terminal: http://127.0.0.1:8091, switch to Record
proxymock web                                    # 3. browse the recorded traffic (:7788)
proxymock mock -- dotnet run                       # 4. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 5. replay (or use Replay in proxymock web)
```

`proxymock record` exports the proxy and TLS settings, and `HttpClient` picks them up
automatically — no extra configuration.

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. The dashboard in step 2 drives this flow too — set the endpoint switch to Record, then click through the calls. On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see [`./proxymock/`](./proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../../README.md) and [`openapi.yaml`](../../shared/openapi.yaml).

## Committed workspace

This app's `proxymock/` directory includes its runtime-specific recording and the standard `applications/`, `blueprints/`, and `testconfigs/` companion documents. From this app directory, use the committed capture explicitly:

```shell
proxymock coverage --in proxymock/recording
proxymock replay --in proxymock/recording --test-against http://localhost:8080
```

Start the app under `proxymock mock --in proxymock/recording -- <app command>` in another terminal first; use the app command shown above. The blueprint chains fresh access tokens and order IDs. Coverage reports the happy-path calls and the missing error responses. New captures and replay results remain local and are ignored by git.
