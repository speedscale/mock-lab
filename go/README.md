# Go demo app

The Go version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).

## Run

```shell
go run .
```

Set `EMIT_TELEMETRY=1` to enable the opt-in telemetry beacon. It fires several extra outbound
calls per API request, each rotating on every run so a replay produces mock misses by
construction — the raw material for the [mock match-rate tuning
guide](https://docs.speedscale.com/proxymock/guides/mock-match-rate/). Off by default; the
beacon is fire-and-forget and never affects API responses. Each call exercises a different
capability of the match-rate tuner:

| Beacon call | Exercises |
| --- | --- |
| `POST /v1/track/{uuid}` + `ts` in body | rotating UUID in the path (the baseline) |
| `POST /v1/track/{ulid}?ts=&sid=&oid=&u7=&xid=&ksuid=` | **time-anchored ids** — a ULID path segment plus a bare epoch, Snowflake, Mongo ObjectId, UUIDv7, xid, and KSUID query params. Each embeds this run's time; the tuner recognizes them as volatile because their decoded time lands in the recording's capture window (the disambiguation that lets a bare epoch be told from an ordinary numeric id). |
| `POST /graphql` | **GraphQL** — a rotating `variables.id` with a fixed `operationName`/`query`. The tuner recommends masking only the variable, never the operation identity (every GraphQL call shares one URL, so masking `query` would collapse distinct operations). |
| `GET /v1/feed` → `GET /v1/feed?cursor=…` | **correlation / provenance** — the second request pages with the cursor the first *response* handed back. A rotating value that flows response→request is a correlation to *bind*, not noise to mask; `POST /api/mocks/provenance` surfaces the edge. Needs a downstream that issues a `nextCursor` (the lab reference server's `/v1/feed`), so run with `DOWNSTREAM_URL=http://localhost:8090` against `../lab/server` to see it. |

The app's own auth + order flow (below) is a second correlation example: the `access_token`
and `order_id` flow response→request too.

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
