# sqlcommenter + proxymock: which request ran this query?

A recording of database traffic holds every statement an app ran, but not which inbound request ran it. proxymock can guess from timing: a statement belongs to the request that was running when it ran. That guess is right when requests take turns and wrong when they overlap, which is exactly when you need it.

This lab's app removes the guess. It is a small orders API on Postgres that tags every SQL statement with a [sqlcommenter](https://google.github.io/sqlcommenter/spec/) comment carrying the inbound request's W3C `traceparent` and route:

```sql
SELECT id, customer, total::float8, created_at FROM orders WHERE id = $1 /*db_driver='pgx',route='%2Forders%2F%7Bid%7D',traceparent='00-8518655f3f985a63bbedceb6d0359555-6d1c2b8e4f0a9e17-01'*/
```

proxymock reads the comment and links each statement to the inbound request with the same trace id, exactly. The lab ships a recording with every case in it: overlapping requests, an untagged query, a prepared statement reused by later requests, and requests that arrive without a trace.

It also ships the same load recorded from the same app with tracing switched off, so you can see what linking by timing gets right and what it gets wrong. See [4. Compare with no tracing](#4-compare-with-no-tracing).

## Prerequisites

- Go 1.25 or newer
- Docker with Compose, for Postgres
- proxymock 2.5.1153 or newer, installed, initialized, and on `PATH`. Older versions do not read trace context from SQL comments.
- Optional: an MCP client with STDIO support, for [AGENT_TASK.md](AGENT_TASK.md)

Run every command below from this `sqlcommenter` directory of your `mock-lab` clone.

The lab pins Postgres 16.10 and binds it to `127.0.0.1:54330`, next to the agent tutorial's `tutorial-db` on 54329. The app listens on `:8080`, like the other labs.

## How the app tags its SQL

[`sqlcomment.go`](sqlcomment.go) holds the whole mechanism, in about a hundred lines and with no tracing library:

- A middleware reads the inbound `traceparent` header and continues that trace with a new span id of its own. When no valid `traceparent` arrives, the app starts a new trace.
- The trace context and the route template (such as `/orders/{id}`) go into the request context.
- `tag(ctx, sql)` appends the comment in the sqlcommenter format: keys sorted, values URL-encoded and single-quoted.
- The app echoes the `traceparent` it used in the response, so `curl -i` shows the trace id to look for.

The `SQL_COMMENTS` environment variable picks how much of this the app does, so the same app can stand in for a service at each level of instrumentation:

| `SQL_COMMENTS` | Traces requests | SQL comment | Stands in for |
|---|---|---|---|
| `trace` (default) | Yes, and echoes `traceparent` | `route` and `traceparent` | An OpenTelemetry sqlcommenter integration |
| `route` | No | `route` only | Rails query log tags or marginalia without tracing |
| `off` | No | None | A service with no SQL tagging |

In a real service an OpenTelemetry SDK and a sqlcommenter integration do this for you. [Link queries to the request that ran them](https://docs.speedscale.com/proxymock/guides/link-queries-to-requests/) lists the setup for each framework.

The app uses `github.com/jackc/pgx/v5` with its default statement cache, so most statements go over the wire as the extended protocol: Parse, Describe, Bind, Execute.

| Endpoint | SQL | Tagged |
|---|---|---|
| `GET /health` | `SELECT count(*) FROM products` | No: health checks are rarely traced |
| `GET /products` | One `SELECT` | Yes |
| `GET /products/{id}` | A named prepared statement, prepared once per connection and reused (see below) | Only the request that prepared it |
| `GET /orders/{id}` | The order, then its items | Yes |
| `POST /orders` | A transaction: `BEGIN`, `INSERT`, an `UPDATE` and an `INSERT` per item, `UPDATE`, `COMMIT` | Yes, `BEGIN` and `COMMIT` included |
| `GET /reports/sales` | `SELECT pg_sleep(0.2)`, then an aggregate | Yes |

`GET /reports/sales` is slow on purpose, so that concurrent reports overlap. That is when linking by timing becomes a guess and the trace id decides.

### The prepared statement caveat

`GET /products/{id}` prepares its statement once per connection, by whichever request gets there first, and every later request on that connection reuses it. This is what an ORM statement cache keyed on the uncommented SQL does, and it is the caveat of comment tagging: the reused statement keeps the comment of the request that prepared it, so it names a trace that has already finished.

proxymock only links a statement by trace id when the request with that trace id also contains the statement in time. A stale comment fails that check, so those executions fall back to timing instead of linking to the wrong request.

## 1. Look at the committed recording

`proxymock/recording` is one run of the capture in step 3, with `SQL_COMMENTS=trace`. You can read it without starting anything:

```shell
make test
make report
```

`make report` runs `proxymock sql-report` on the recording. The per-request section opens with:

```text
Statements per inbound request (18 requests, 31 statements attributed, 20 of them by the trace id in their SQL comment, 1 outside any request):
```

Then open it in proxymock web:

```shell
make web
```

- Open any Postgres pair. Its detail shows **Caused by** with the request that ran it, marked **by trace id** when the comment named that request and **by time** when proxymock inferred it.
- Open the **Trace** lens on the Requests list. Database calls linked through their comment get a chain badge, and the header counts how many were linked by trace ID and how many by timing.
- Add the filter **Trace ID** with the id from a `/reports/sales` request. The list narrows to that request and the queries it ran, even though three other reports were running at the same time.
- Use the **Run** selector to switch between `recording` and `recording-no-otel`, the same load with no tracing. Step 4 walks through the difference.

## 2. Start Postgres

```shell
make up
```

`make down` stops it and deletes its data.

## 3. Record your own run

```shell
make capture
```

The capture target recreates the database, starts the app under `proxymock record` with a Postgres listener on port 15432 that forwards to the compose database, sends [`scripts/load.sh`](scripts/load.sh) through the inbound proxy on port 4143, and stops cleanly. It replaces `proxymock/recording`; `git checkout proxymock/recording` restores the committed one.

The load script prints the trace id of every request it sends:

- one untagged health check
- one request at a time to `/products`, `/orders/1` and `POST /orders`, each with its own trace
- four overlapping `/reports/sales` requests, each with its own trace
- eight product lookups through the reused prepared statement
- two requests with no `traceparent`, so the app starts the trace itself

To drive the app by hand instead, start it with `PGPORT=15432 go run .` under `proxymock record --map 15432=postgres://localhost:54330 --app-port 8080` and send requests to port 4143.

`TRACEPARENT=off` makes the load script send every request without a `traceparent`, as if nothing upstream traced them. Combine it with `SQL_COMMENTS` to record any level, for example `SQL_COMMENTS=route TRACEPARENT=off make capture RECORDING_DIR=proxymock/recording-route`.

## 4. Compare with no tracing

`proxymock/recording-no-otel` is the same load from the same app with `SQL_COMMENTS=off` and `TRACEPARENT=off`: no request carries a trace and no statement carries a comment. Record your own with:

```shell
make capture-no-otel
```

Then compare the two recordings:

```shell
make report RECORDING_DIR=proxymock/recording-no-otel
```

Every statement still links to a request, by timing, and the totals match the traced recording: 18 requests and 31 statements attributed. What changes is who ran what while requests overlapped:

| | `recording` (`SQL_COMMENTS=trace`) | `recording-no-otel` |
|---|---|---|
| Linked by trace id | 20 | 0 |
| Ambiguous: linked by timing while requests overlapped | 0 | 8 |
| `GET /reports/sales` statements per request | 2.0, max 2 | 2.0, max 7 |
| **N queries in this request** on the four reports | 2, 2, 2, 2 | 7, 1, 0, 0 |
| **Caused by** on a report's aggregate query | The report with the same trace id, **by trace id** | Whichever report was in flight, **by time** |

Each report runs the same two statements. Timing hands all eight of them to whichever report was in flight, so one report looks like it ran seven queries and two look like they ran none. `sql-report` flags it under the per-request table: `note: 8 statements ran while requests overlapped; per-request figures are approximate.` The order transaction, the order lookups and the product lookups ran one at a time, so timing links them correctly.

Which report collects the statements depends on scheduling, so a new capture can give 7 rather than 8 ambiguous statements, or a busiest report of 8.

## Validated reference evidence

[`evidence/reference.json`](evidence/reference.json) holds the `sql-report` figures for the committed recording, checked statement by statement against **Caused by**:

- 20 statements are linked by trace id: the 8 in the order transaction, the 8 in the four overlapping reports, the 2 for `/orders/1`, the 1 for `/products`, and the first product lookup, which prepared the statement.
- 11 are linked by timing: the untagged health check, the 7 product lookups that reused a statement prepared by an earlier request, and the 3 statements of the two requests that arrived without a `traceparent`.
- 1 ran outside any request: the start-up schema and seed.
- None are ambiguous. The four reports overlap, but their trace ids, not their timing, decided where their statements belong.

`sql-report -o json` gives the same figures as `requestLoad.exactStatements`, `attributedStatements`, `ambiguousStatements` and `unattributedStatements`. A new capture gives the same counts; only the trace ids and timestamps change.

[`evidence/reference-no-otel.json`](evidence/reference-no-otel.json) holds the figures for `proxymock/recording-no-otel`, including the queries per request of the four reports and how much they moved across five captures.

## Measurement boundaries

- Only statements that run SQL are counted: a Postgres Query or Execute. The Parse, Describe and Bind messages around an Execute carry the same SQL and are not counted again.
- A request that arrives without a `traceparent` carries no trace id of its own, so its statements link by timing. A service that starts a trace and then calls another service passes the trace on in that call, and proxymock uses the call to link the statements exactly. This app makes no outbound calls, so its self-started traces link by timing.
- proxymock reads trace context from the traffic only. It does not add headers or comments to anything.

## Run the tests

```shell
make test
```

The tests check the comment format against the sqlcommenter spec and the trace context handling. They need no database.

## Primary references

- [sqlcommenter specification](https://google.github.io/sqlcommenter/spec/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [Link queries to the request that ran them](https://docs.speedscale.com/proxymock/guides/link-queries-to-requests/), the proxymock guide with setup for Rails, Django, Spring, Node, Go and Datadog
