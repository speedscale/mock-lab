# sqlcommenter + proxymock: which request ran this query?

A recording of database traffic holds every statement an app ran, but not which inbound request ran it. proxymock can guess from timing: a statement belongs to the request that was running when it ran. That guess is right when requests take turns and wrong when they overlap, which is exactly when you need it.

This lab's app removes the guess. It is a small orders API on Postgres that tags every SQL statement with a [sqlcommenter](https://google.github.io/sqlcommenter/spec/) comment carrying the inbound request's W3C `traceparent` and route:

```sql
SELECT id, customer, total::float8, created_at FROM orders WHERE id = $1 /*db_driver='pgx',route='%2Forders%2F%7Bid%7D',traceparent='00-8518655f3f985a63bbedceb6d0359555-6d1c2b8e4f0a9e17-01'*/
```

proxymock reads the comment and links each statement to the inbound request with the same trace id, exactly. The lab ships a recording with every case in it: overlapping requests, an untagged query, a prepared statement reused by later requests, and requests that arrive without a trace.

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

`proxymock/recording` is one run of the capture in step 3. You can read it without starting anything:

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

## Validated reference evidence

[`evidence/reference.json`](evidence/reference.json) holds the `sql-report` figures for the committed recording, checked statement by statement against **Caused by**:

- 20 statements are linked by trace id: the 8 in the order transaction, the 8 in the four overlapping reports, the 2 for `/orders/1`, the 1 for `/products`, and the first product lookup, which prepared the statement.
- 11 are linked by timing: the untagged health check, the 7 product lookups that reused a statement prepared by an earlier request, and the 3 statements of the two requests that arrived without a `traceparent`.
- 1 ran outside any request: the start-up schema and seed.
- None are ambiguous. The four reports overlap, but their trace ids, not their timing, decided where their statements belong.

`sql-report -o json` gives the same figures as `requestLoad.exactStatements`, `attributedStatements`, `ambiguousStatements` and `unattributedStatements`. A new capture gives the same counts; only the trace ids and timestamps change.

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
