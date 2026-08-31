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
| `GET /v1/feed` → `GET /v1/feed?cursor=…` | **correlation / provenance** — the second request pages with the cursor the first *response* handed back. A rotating value that flows response→request is a correlation to *bind*, not noise to mask; `POST /api/mocks/provenance` surfaces the edge. |
| `GET /v1/job/status` ×3 | **stateful endpoint** — the same request (fixed URL, no query, no body) is answered with a cycling `status` (pending→running→done). A mock keys on the signature, so it can only replay one response; the tuner flags it as needing a *sequenced* mock, not a mask. Its `checkedAt` timestamp rotates every call and is split out as volatile noise. |
| `GET /v1/time` ×2 | **differential noise probe** — the response differs *only* in a rotating `now` timestamp. A whole-body comparison would wrongly call this stateful; the field-level probe discounts the volatile leaf and leaves the endpoint unflagged, listing `now` as an observed-volatile response field. |
| `POST /v1/orders` → `GET /v1/orders/{id}` | **create→use id** — the POST mints a fresh order id (in `Location` + body) that the GET then uses in its path. The tuner recognizes the create→use chain and does *not* wildcard `/v1/orders/*` (that would match ids the mock never issued); at mock time the client reuses the issued id, so it self-satisfies. |
| `POST /v1/auth/token` → `GET /v1/me` | **credentials / session** — a fresh access token and a rotated `SESSIONID` cookie are issued, then replayed in the `Authorization` and `Cookie` headers. Headers are outside the mock signature, so these never cause a miss; the tuner surfaces them under *Credentials & session* to correlate for a validating replay, not to mask. |
| `GET /v1/inventory/{sku}` ×up to 3 | **chaos / resilience** — the one flow that does *not* rotate. A fixed SKU and a constant body make the replay a reliable cache hit, because chaos perturbs a *matched* response and a rotating value would produce misses instead. The call is wrapped in the retry-and-timeout logic a resilient client is supposed to have, so a chaos rule scoped to this path produces an observable outcome rather than a silent one. |

The cursor, poll, create→use, and auth flows all call the **lab reference server** for their
routes, so run the beacon with `DOWNSTREAM_URL=http://localhost:8090` against `../lab/server`
to exercise them (`cd ../lab/server && go run .` in another terminal). The app's own auth +
order flow (below) is a further correlation example: the `access_token` and `order_id` flow
response→request too.

The [mock match-rate tuning guide](https://docs.speedscale.com/proxymock/guides/mock-match-rate/)
uses the beacon to demonstrate the `improve-mock-match-rate` skill and the proxymock MCP
tuning tools (`analyze_mock_matches`, `accept_mock_recommendation`, `similar_candidates`):
record with the beacon on, mock + replay, then let an AI agent tune the blueprint until the
match rate is 100%.

## Chaos: does the client actually survive it?

Recording `/v1/inventory/{sku}` is unremarkable — one call, one 200. The point is replaying it
through a mock with a chaos rule scoped to that path. The scope is an ordinary
[filter query](https://docs.speedscale.com/reference/filters/), the same syntax the Filters dialog
uses:

```shell
proxymock mock --in ./proxymock \
  --chaos '(location REGEX "^/v1/inventory"): status=503,percent=50,seed=demo' \
  -- go run .
```

Then drive the API (`curl localhost:8080/api/projects`) a few times and watch the app's own log. The
retry loop reports what it saw, and the `X-Speedscale-Chaos` header names the effects that fired and
the rule that fired them, so a perturbed attempt is distinguishable from an ordinary upstream error:

```
resilience: attempt 1/3 got 503 [chaos: effect=status code;rule=chaos-1]
resilience: attempt 2/3 got 503 [chaos: effect=status code;rule=chaos-1]
resilience: recovered on attempt 3/3 in 307ms (70 bytes)
```

...and, on a less lucky run of the *same* rule:

```
resilience: attempt 3/3 got 503 [chaos: effect=status code;rule=chaos-1]
resilience: GAVE UP after 3 attempts in 307ms - the client did not survive this
```

Both outcomes come from one rule because `percent` is a per-occurrence probability: a flaky endpoint
is a *rate*, not a fixed verdict on an endpoint. `seed=demo` makes the sequence reproducible, so a
failing run can be replayed exactly.

Other effects worth pointing at the same path:

| Rule | Exercises |
| --- | --- |
| `(location REGEX "^/v1/inventory"): latency=3s` | the client's 2s timeout — the retry loop reports `context deadline exceeded` |
| `(location REGEX "^/v1/inventory"): no-response` | a connection closed with no reply at all |
| `(location REGEX "^/v1/inventory"): body=corrupt` | a 200 whose body no longer parses |
| `(location REGEX "^/v1/inventory") AND (command IS "GET"): status=503,latency=1s` | composed effects, both applied to the same response |

Every chaosed response is tagged in the recording too, so `proxymock web` shows a **Chaos** column
naming the effects, and the chaos-only filter narrows the grid to just the perturbed calls.

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
