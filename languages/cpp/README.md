# C++ demo app

The C++ version of the [mock-lab](../../README.md) proxymock demo. It serves an HTTP API on
`:8080` (POSIX sockets) and fulfills each request by calling the CNCF projects API downstream
via libcurl (`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).

Needs a C++17 compiler and **libcurl** (`libcurl4-openssl-dev` on Debian/Ubuntu; preinstalled in the devcontainer).

Use the installed [agent skills](../../README.md#agent-skills) to create tests from this app's recording and schema. The dashboard is optional.

## Run

```shell
c++ -std=c++17 main.cpp -o app -lcurl
./app
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
c++ -std=c++17 main.cpp -o app -lcurl
proxymock record -- ./app                        # 1. record the downstream calls
proxymock web                                    # 2. browse the recorded traffic (:7788)
proxymock mock -- ./app                           # 3. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 4. replay (or use Replay in proxymock web)
```

`proxymock record` exports the proxy and TLS settings. libcurl honors the `*_proxy` env
vars on its own, but — unlike the `curl` CLI — the library does **not** read `SSL_CERT_FILE`
(it uses a compiled-in CA bundle), so the app sets `CURLOPT_CAINFO` from `$SSL_CERT_FILE`
to trust proxymock's TLS. Without that, the downstream call fails verification on Linux.

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
