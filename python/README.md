# Python demo app

The Python version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Standard library only.

## Run

```shell
python3 app.py
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
proxymock record -- python3 app.py                # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- python3 app.py                   # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

`proxymock record` exports the proxy and TLS settings, and `urllib` picks them up
automatically — no extra configuration.

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. Drive the flow with `../lab/tests/run_auth_tests.sh` (add `--recording` to capture it through proxymock). On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see the [root README](../README.md#auth-handshake--the-two-moving-ids) and [`../lab/proxymock/`](../lab/proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
