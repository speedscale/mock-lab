# SQL Server: record, mock and replay a database

A shop API that keeps its products and orders in Microsoft SQL Server, written four times: in Go, Java, Node.js and Python, each with that language's usual SQL Server driver. Each one is recorded with proxymock, run with SQL Server mocked, and its recorded SQL replayed against the real database, as a regression test and as a load test.

| Language | Driver | How its SQL crosses the wire |
|---|---|---|
| Go | [go-mssqldb](https://github.com/microsoft/go-mssqldb) | `sp_executesql` with typed parameters; transactions as transaction manager requests; the stored procedure as an RPC by name |
| Java | [mssql-jdbc](https://github.com/microsoft/mssql-jdbc) 12.10 | `sp_executesql` for every prepared statement; transactions as `set implicit_transactions on` and `IF @@TRANCOUNT > 0 COMMIT TRAN` batches; the stored procedure as `EXEC` inside `sp_executesql` |
| Node.js | [mssql](https://github.com/tediousjs/node-mssql) 12 (tedious) | `sp_executesql`; transactions as transaction manager requests; the stored procedure as an RPC by name |
| Python | [pymssql](https://github.com/pymssql/pymssql) 2.4 (FreeTDS) | Plain SQL batches with the values written into the text by the driver; an attention (cancel) each time a cursor closes with rows left unread |

All four connect with encryption on (`encrypt=true` and trust the server certificate, or `encryption="require"`), so every call goes over TLS inside TDS and proxymock decrypts it to record it.

## Prerequisites

- Docker with Compose. The SQL Server 2022 image is linux/amd64 only; Docker Desktop on Apple silicon runs it under emulation and it takes a minute or two to start the first time.
- proxymock installed, initialized and on `PATH`, in a release with SQL Server replay. An earlier release cannot run steps 4 to 7.
- For the apps you want to run: Go 1.25, JDK 17 and Maven, Node.js 20, Python 3.10.

Run every command below from this `sqlserver` directory of your `mock-lab` clone. `make build` builds all four apps; `make build-go` (or `-java`, `-node`, `-python`) builds one.

The lab binds SQL Server to `127.0.0.1:14330`, so it can run next to a SQL Server you already have on 1433. Every app listens on `:8080` and reads `DB_HOST` and `DB_PORT`, which default to `localhost:11433`: the port proxymock listens on for SQL Server in every step below.

## The app

| Endpoint | SQL |
|---|---|
| `GET /health` | `SELECT 1` |
| `GET /products?category=` | One `SELECT` with a parameter |
| `GET /products/{id}` | One `SELECT` by id; 404 when there is no row |
| `POST /orders` | A transaction: `SELECT ... WITH (UPDLOCK)`, `UPDATE` the stock, `INSERT ... OUTPUT INSERTED.id`, `COMMIT`; it rolls back with 409 when the stock is too low and 404 when the product does not exist |
| `GET /orders/{id}` | A join of the order and its product |
| `GET /reports/top-products?limit=` | The stored procedure `dbo.top_products`, which returns rows, an `OUTPUT` parameter and a return status |

[`db/schema.sql`](db/schema.sql) creates the `shop` database, the `app` login and nine products. Loading it again resets the data, which every step that writes does first.

[`scripts/drive.sh`](scripts/drive.sh) sends the same 17 requests every time, including an order that sells the last chain, one that then finds it out of stock, and one for a product that does not exist. It prints one line per request. Against a freshly loaded database every app prints exactly [`expected.txt`](expected.txt), which is how each step below checks its result.

## 1. Look at the committed recordings

`proxymock/recording-go`, `-java`, `-node` and `-python` are one run of step 3 for each app. Each holds the 17 inbound requests in `localhost/` and the app's SQL Server calls in `localhost-14330/`. Open them without starting anything:

```shell
make web
```

Use the **Run** selector to switch between the four recordings, and compare the same requests across drivers:

- `POST /orders` from Go opens and ends its transaction with **Begin Transaction** and **Commit Transaction** requests, with three `sp_executesql` calls between them. Java sends `set implicit_transactions on` before them and `IF @@TRANCOUNT > 0 COMMIT TRAN` after. Python sends `BEGIN TRANSACTION` and `COMMIT TRANSACTION` as SQL text.
- `GET /products/1` from Python is the SQL batch `SELECT ... WHERE id = 1`, with the id in the text, and an **Attention** follows it: pymssql cancels the rest of a result when its cursor closes.
- `dbo.top_products` from Go or Node returns its rows, then a return status and the `@total` output parameter.

## 2. Start SQL Server

```shell
make up
```

It starts SQL Server and loads `db/schema.sql`. `make down` removes it, with its data.

## 3. Record an app

```shell
make record APP=java
```

[`scripts/record.sh`](scripts/record.sh) reloads the database, starts the recorder, starts the app pointed at it, and sends the request sequence through it:

```text
drive.sh ──► :4143 proxymock ──► :8080 shop ──► :11433 proxymock ──► :14330 SQL Server
```

The recorder is one command, with a port map for SQL Server:

```shell
proxymock record --app-port 8080 --map 11433=localhost:14330
```

It ends with a count, such as `Recorded 17 inbound requests and 40 SQL Server calls in proxymock/recording-java`, and fails if the app answered any request differently from `expected.txt`. `make record-all` records all four apps.

## 4. Run an app with SQL Server mocked

Stop SQL Server first, to see that nothing reaches it:

```shell
docker compose stop mssql
make mock APP=java
```

[`scripts/mock.sh`](scripts/mock.sh) starts the mock on the port the app connects to, starts the app, and sends the request sequence to it:

```shell
proxymock mock --in proxymock/recording-java --no-passthrough --map 11433=mssql://localhost:14330
```

```text
The java app answered all 17 requests as in expected.txt with SQL Server mocked:
  38 SQL Server calls answered from the recording, 0 not
```

The app signs in, negotiates encryption, runs its transactions and its stored procedure, and gets every row back as SQL Server returned it. `--no-passthrough` means a call the recording does not hold would get SQL Server error 50000 instead of reaching a database. `make test` runs this step for all four apps and needs no database at all.

Start SQL Server again for the next steps:

```shell
docker compose start mssql
```

## 5. Replay the recorded SQL against SQL Server

```shell
make replay-db APP=java
```

[`scripts/replay-db.sh`](scripts/replay-db.sh) reloads the database and replays the recording's SQL Server calls against it, with no app running:

```shell
MSSQL_USER=app MSSQL_PASSWORD='Lab-App-2026!' proxymock replay --in proxymock/recording-java \
  --tests-filter '(direction IS OUT) AND (tech IS "SQL Server")' \
  --test-against 'sqlserver://localhost:14330?database=shop&encrypt=true&trustservercertificate=true' \
  --fail-if 'requests.failed != 0' --fail-if 'requests.result-match-pct < 100'
```

proxymock signs in as `app`, sends each recorded statement as the driver sent it, and compares what SQL Server returns with the recording:

```text
2 EVALS PASSED
 ✔ passed eval "requests.failed != 0.00" - observed requests.failed was 0.00
 ✔ passed eval "requests.result-match-pct < 100.00" - observed requests.result-match-pct was 100.00
```

This is a regression test of the database itself: a schema change, a new index or a SQL Server upgrade that breaks a statement the app depends on fails it, without the app. `make replay-db-all` replays all four recordings.

## 6. Replay it twice

```shell
make replay-twice APP=java
```

The same replay runs two passes without reloading the database in between. The second pass fails:

```text
 ✘ failed eval "requests.result-match-pct < 100.00" - observed requests.result-match-pct was 98.68
```

The first pass sold the last chain again, so on the second pass the `UPDATE` that takes its stock breaks the `ck_products_stock` constraint, with SQL Server error 547 where the recording had a row count. A database replay starts from the database it finds, so reload the data before each run, as `make replay-db` does, or rewrite the values that collide; see [Load and Regression Test a Database](https://docs.speedscale.com/proxymock/databases/load-and-regression-testing/).

## 7. Load test SQL Server

```shell
make load APP=java
```

Four virtual users replay the recording in a loop for 30 seconds, each with its own SQL Server session, as fast as the server answers. On a laptop with SQL Server under emulation that was about 200,000 statements, roughly 6,600 a second, with none failing to get an answer.

The table's **RESULT MISMATCH** column shows the same effect as step 6: the `UPDATE` of the stock differs from the recording almost every time, because the stock runs out in the first few loops. Load-test mode reports it without failing on it. While the test runs, the sessions show up in SQL Server with the program name `speedscale-generator`:

```shell
docker compose exec mssql /opt/mssql-tools18/bin/sqlcmd -C -U sa -P 'Lab-Admin-2026!' \
  -Q "SELECT status, count(*) FROM sys.dm_exec_sessions WHERE program_name = 'speedscale-generator' GROUP BY status"
```

## Limits

These come from proxymock, not the lab; [Record SQL Server](https://docs.speedscale.com/proxymock/databases/record/sqlserver/) lists them all.

- The mock and the replay sign in with SQL Server logins (and the replay also with Microsoft Entra ID), not Windows authentication.
- MARS connections, bulk loads and Always Encrypted columns are recorded only in part, and are not mocked or replayed.
- The replay compares status and errors with the recording, not the rows a statement returns.
