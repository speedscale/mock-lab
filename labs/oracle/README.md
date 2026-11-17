# Oracle: record, mock and replay a database

A shop API that keeps its products and orders in Oracle Database, written four times: in Go, Java, Node.js and Python, each with that language's usual Oracle driver in thin mode. Each one is recorded with proxymock, run with Oracle mocked, and its recorded SQL replayed against the real database, as a regression test and as a load test.

| Language | Driver | How its SQL crosses the wire |
|---|---|---|
| Go | [go-ora](https://github.com/sijms/go-ora) 2.9 | Negotiates the protocol and the data types in their own messages before it signs in. Sends the SQL text with named binds on every execute, and closes each cursor right after, in a ping that carries the close. `COMMIT` and `ROLLBACK` are calls of their own. The procedure is an anonymous PL/SQL block, then a fetch on the REF CURSOR it returns |
| Java | [Oracle JDBC thin](https://www.oracle.com/database/technologies/appdev/jdbc.html) (ojdbc11 23.26) | Sends the SQL text with positional binds (`:1`) on every execute, with the previous cursor's close attached to the next call. `getGeneratedKeys` first describes the `ORDERS` table, then sends the insert with `RETURNING id INTO :4` added by the driver. `{call top_products(?, ?, ?)}` arrives as `BEGIN top_products(:1, :2, :3); END;` |
| Node.js | [node-oracledb](https://github.com/oracle/node-oracledb) 26 | Keeps statements in its statement cache: the first execute sends the SQL text, later ones name only the cursor. A query returns 2 rows with its execute and fetches the rest. `COMMIT` and `ROLLBACK` are calls of their own |
| Python | [python-oracledb](https://github.com/oracle/python-oracledb) 26.1 | The same statement cache and 2-row prefetch as node-oracledb. The pool sends a `ROLLBACK` each time a connection goes back to it. `callproc` sends `begin top_products(:1,:2,:3); end;` |

All four connect over plain TCP. The lab does not cover TCPS: the database would need a wallet with a server certificate in the container.

## Prerequisites

- Docker with Compose. The lab runs the `gvenzl/oracle-free:23-slim-faststart` image of Oracle Database 23ai Free, which runs natively on amd64 and arm64. It is a large image, about 7 GB, and once it is pulled it starts in well under a minute.
- proxymock installed, initialized and on `PATH`, in a release with Oracle replay. An earlier release cannot run steps 3 to 7.
- For the apps you want to run: Go 1.25, JDK 17 and Maven, Node.js 20, Python 3.10.

Run every command below from this `oracle` directory of your `mock-lab` clone. `make build` builds all four apps; `make build-go` (or `-java`, `-node`, `-python`) builds one.

The lab binds Oracle to `127.0.0.1:15210`, so it can run next to an Oracle you already have on 1521. Every app listens on `:8080` and reads `DB_HOST`, `DB_PORT` and `DB_SERVICE`, which default to `localhost:11521` and `FREEPDB1`: 11521 is the port proxymock listens on for Oracle in every step below.

## The app

| Endpoint | SQL |
|---|---|
| `GET /health` | `SELECT 1 FROM dual` |
| `GET /products?category=` | One `SELECT` with a bind |
| `GET /products/{id}` | One `SELECT` by id; 404 when there is no row |
| `POST /orders` | A transaction: `SELECT ... FOR UPDATE`, `UPDATE` the stock, `INSERT ... RETURNING id INTO :order_id`, `COMMIT`; it rolls back with 409 when the stock is too low and 404 when the product does not exist |
| `GET /orders/{id}` | A join of the order and its product |
| `GET /reports/top-products?limit=` | The procedure `top_products`, which returns its rows in a REF CURSOR OUT parameter and the order count in a `NUMBER` OUT parameter |

The procedure returns a REF CURSOR rather than an implicit result, because go-ora cannot read implicit results.

[`db/schema.sql`](db/schema.sql) creates the tables, the procedure and nine products in the schema of the user `shop`, which the image creates in `FREEPDB1` on its first start. Loading it again resets the data, which every step that writes does first.

[`scripts/drive.sh`](scripts/drive.sh) sends the same 17 requests every time, including an order that sells the last chain, one that then finds it out of stock, and one for a product that does not exist. It prints one line per request. Against a freshly loaded database every app prints exactly [`expected.txt`](expected.txt), which is how each step below checks its result.

## 1. Look at the committed recordings

`proxymock/recording-go`, `-java`, `-node` and `-python` are one run of step 3 for each app. Each holds the 17 inbound requests in `localhost/` and the app's Oracle calls in `localhost-15210/`. Open them without starting anything:

```shell
make web
```

Use the **Run** selector to switch between the four recordings, and compare the same requests across drivers:

- `POST /orders` from Node.js is an **Execute** of the `SELECT ... FOR UPDATE`, two more for the `UPDATE` and the `INSERT`, and a **Commit**. The insert's response holds the new order id as its OUT bind.
- `GET /products?category=parts` from Python is an **Execute** that names only the cursor the first category query opened, and returns 2 rows, then a **Fetch** for the third.
- `GET /products/1` from Go is an **Execute** with the SQL text, then a **Ping** that closes its cursor.
- `top_products` from any app is an **Execute** of the PL/SQL block, then an **Execute** on the cursor id it returned, which reads the rows.

None of them holds `GET /health`'s `SELECT 1 FROM dual`: proxymock treats it as a connection check, leaves it out of the recording, and the mock answers it by itself.

## 2. Start Oracle

```shell
make up
```

It starts Oracle and loads `db/schema.sql`. `make down` removes it, with its data.

## 3. Record an app

```shell
make record APP=node
```

[`scripts/record.sh`](scripts/record.sh) reloads the database, starts the recorder, starts the app pointed at it, and sends the request sequence through it:

```text
drive.sh ──► :4143 proxymock ──► :8080 shop ──► :11521 proxymock ──► :15210 Oracle
```

The recorder is one command, with a port map for Oracle:

```shell
proxymock record --app-port 8080 --map 11521=oracle://127.0.0.1:15210
```

It ends with a count, such as `Recorded 17 inbound requests and 33 Oracle calls in proxymock/recording-node`, and fails if the app answered any request differently from `expected.txt`. `make record-all` records all four apps.

The recording never holds the password. An Oracle login proves the password with keys derived from it, and the recording only notes that they were sent.

## 4. Run an app with Oracle mocked

Pause Oracle first, to see that nothing reaches it:

```shell
docker compose pause oracle
make mock APP=node
```

[`scripts/mock.sh`](scripts/mock.sh) starts the mock on the port the app connects to, starts the app, and sends the request sequence to it:

```shell
proxymock mock --in proxymock/recording-node --no-passthrough --test-config oracle-lab \
  --map 11521=oracle://127.0.0.1:15210
```

```text
The node app answered all 17 requests as in expected.txt with Oracle mocked:
  30 Oracle calls answered from the recording, 0 not
```

An Oracle login is mutual: the driver checks that the server knows its password too, so a mock that does not know it fails every login with ORA-01017. The test config [`proxymock/testconfigs/oracle-lab.json`](proxymock/testconfigs/oracle-lab.json) gives the mock the app user's password in `responder.oracle`, and `--test-config oracle-lab` reads it. A test config's `id` must match its file name.

The app signs in, runs its transactions and its procedure, and gets every row back as Oracle returned it. `--no-passthrough` means a call the recording does not hold gets ORA-20999 instead of reaching a database. `make test` runs this step for all four apps and needs no database at all.

Unpause Oracle for the next steps:

```shell
docker compose unpause oracle
```

## 5. Replay the recorded SQL against Oracle

```shell
make replay-db APP=node
```

[`scripts/replay-db.sh`](scripts/replay-db.sh) reloads the database and replays the recording's Oracle calls against it, with no app running:

```shell
ORACLE_USER=shop ORACLE_PASSWORD=LabShop2026 proxymock replay --in proxymock/recording-node \
  --tests-filter '(direction IS OUT) AND (tech IS Oracle)' \
  --test-against oracle://127.0.0.1:15210/FREEPDB1 \
  --fail-if 'requests.failed != 0' --fail-if 'requests.result-match-pct < 100'
```

proxymock signs in as `shop`, sends each recorded statement as the driver sent it, and compares what Oracle returns with the recording:

```text
2 EVALS PASSED
 ✔ passed eval "requests.failed != 0.00" - observed requests.failed was 0.00
 ✔ passed eval "requests.result-match-pct < 100.00" - observed requests.result-match-pct was 100.00
```

This is a regression test of the database itself: a schema change, a new index or an Oracle upgrade that breaks a statement the app depends on fails it, without the app. `make replay-db-all` replays all four recordings.

## 6. Replay it twice

```shell
make replay-twice APP=node
```

The same replay runs two passes without reloading the database in between. The second pass fails:

```text
 ✘ failed eval "requests.result-match-pct < 100.00" - observed requests.result-match-pct was 98.33
```

The first pass sold the last chain again, so on the second pass the `UPDATE` that takes its stock breaks the `ck_products_stock` constraint, with ORA-02290 where the recording had a row count. A database replay starts from the database it finds, so reload the data before each run, as `make replay-db` does, or rewrite the values that collide; see [Load and Regression Test a Database](https://docs.speedscale.com/proxymock/databases/load-and-regression-testing/).

## 7. Load test Oracle

```shell
make load APP=node
```

Four virtual users replay the recording in a loop for 30 seconds, each with its own Oracle session, as fast as the server answers. On a laptop that was about 137,000 statements for the Node.js recording, roughly 4,600 a second.

The table's **RESULT MISMATCH** column shows the same effect as step 6: the `UPDATE` of the stock differs from the recording almost every time, because the stock runs out in the first few loops. Load-test mode reports it without failing on it. While the test runs, the sessions show up in Oracle under the program name the app's driver recorded:

```shell
docker compose exec -T oracle sqlplus -S -L system/LabAdmin2026@//localhost/FREEPDB1 <<'SQL'
SELECT program, status, COUNT(*) FROM v$session WHERE username = 'SHOP' GROUP BY program, status;
SQL
```

## Limits

These come from proxymock, not the lab; [Record Oracle](https://docs.speedscale.com/proxymock/databases/record/oracle/) lists them all.

- The mock and the replay need the database password of each user the app signs in as.
- The lab does not cover TCPS, and proxymock does not record, mock or replay sessions that use Native Network Encryption.
- The replay compares status and errors with the recording, not the rows a statement returns.
