# proxymock tutorial app

The demo service for the proxymock getting-started tutorial, where a coding agent records traffic, tunes the tests and mocks, and runs a regression test and a performance test.

It is a small CNCF swag shop: an HTTP API that prices orders by looking up CNCF projects on a hosted API and stores them in Postgres. The same service is written in four languages that behave identically, so the tutorial reads the same whichever you pick.

| Language | Directory | Stack |
| --- | --- | --- |
| Go | [go/](go/) | net/http, pgx |
| Java | [java/](java/) | Spring Boot, JdbcTemplate |
| Python | [python/](python/) | FastAPI, httpx, psycopg |
| Node.js | [node/](node/) | Express, pg |

## Quick start

1. Start the database (below). No Docker needed.
2. Follow the README in your language's directory to run the app and send it traffic.

## Start the database

`tutorial-db` runs a real Postgres 16 as an ordinary process on macOS, Linux and Windows, with the tutorial schema loaded. Start it from this `tutorial/` directory, in its own terminal; it runs until Ctrl-C.

With Go installed:

```sh
go -C db run .
```

Without Go, download it once. macOS and Linux:

```sh
curl -fsSLo tutorial-db "https://github.com/speedscale/mock-lab/releases/download/tutorial-db/tutorial-db-$(uname -s | tr A-Z a-z)-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" && chmod +x tutorial-db
./tutorial-db
```

Windows (PowerShell):

```powershell
curl.exe -fsSLo tutorial-db.exe https://github.com/speedscale/mock-lab/releases/download/tutorial-db/tutorial-db-windows-amd64.exe
.\tutorial-db.exe
```

It listens on `localhost:54329` with user, password and database all `tutorial`, which is every port's default `DATABASE_URL`, and keeps its data and its downloaded Postgres in `.tutorial-db/`. The first start downloads about 30 MB.

| Command | Effect |
| --- | --- |
| `tutorial-db -stop` | Stop it from another terminal (the way to stop it on Windows when it runs in the background) |
| `tutorial-db -reset` | Delete the data, then start empty |
| `tutorial-db -exec "SQL"` | Run a statement against the running database, for example `TRUNCATE order_items, orders` |
| `tutorial-db -port N` | Listen on another port; point `DATABASE_URL` at it |

## What is in here

* [contract/SPEC.md](contract/SPEC.md): the behavior every port implements, including the exact SQL, the JSON shapes, and the planted work the tutorial chapters find and fix.
* [contract/openapi.yaml](contract/openapi.yaml): the API.
* [contract/schema.sql](contract/schema.sql): the database schema, loaded by `tutorial-db`.
* [db/](db/): `tutorial-db`, the Postgres runner.
* [contract/traffic.json](contract/traffic.json): the request sequence each language's traffic driver sends (135 requests).
* [conformance/](conformance/): checks that a port's recording has the same shape as the Go reference.

## Switches the tutorial uses

| Variable | Effect |
| --- | --- |
| `APP_VERSION=v2` | `total_cents` is returned as a string. The regression test catches it. |
| `APP_SLOW=1` | `GET /orders` runs one query per order. The performance test catches it. |
