# Go demo app

The Go version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).

## Run

```shell
go run .
```

Set `EMIT_TELEMETRY=1` to enable the opt-in telemetry beacon: every downstream-backed API
request additionally fires `POST /v1/track/{event_id}` with a fresh UUID in the path and a
timestamp in the body. Both rotate on every call, so replaying a recording produces mock
misses — the raw material for the [mock match-rate tuning
guide](https://docs.speedscale.com/proxymock/guides/mock-match-rate/). Off by default; the
beacon is fire-and-forget and never affects API responses.

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
proxymock record -- go run .                     # 1. record the downstream calls
../lab/tests/run_tests.sh --recording            # 2. second terminal: drive every endpoint
proxymock web                                    # 3. browse the recorded traffic (:7788)
proxymock mock -- go run .                        # 4. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 5. replay (or use Replay in proxymock web)
```

`proxymock record` exports the proxy and TLS settings to the child process, and Go's
`net/http` picks them up automatically — no extra configuration.

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. The quickstart's `../lab/tests/run_tests.sh` drives this flow too. On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see the [root README](../README.md#auth-handshake--the-two-moving-ids) and [`../lab/proxymock/`](../lab/proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
