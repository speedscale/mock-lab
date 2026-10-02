# Tutorial orders service (Go)

The Go port of the proxymock getting-started service: a small CNCF swag shop backed by Postgres and the hosted CNCF projects API.

## Prerequisites

* Go 1.25 or newer
* `tutorial-db` for Postgres: see [Start the database](../README.md#start-the-database)
* [proxymock](https://docs.speedscale.com/proxymock/) for the recording step

## Run it

Start the database in its own terminal, from the `tutorial/` directory (it runs until Ctrl-C):

```sh
go -C db run .
```

Run the app, from `tutorial/go/`:

```sh
go run .
```

Run the tests (no database needed):

```sh
go test ./...
```

Drive traffic at the app in a second terminal:

```sh
go run ./cmd/traffic
```

Configuration is by environment variables, listed in [`../contract/SPEC.md`](../contract/SPEC.md) along with the full behavior contract.

## Record it with proxymock

```sh
DATABASE_URL=postgres://tutorial:tutorial@localhost:15432/tutorial?sslmode=disable proxymock record --map 15432=postgres://localhost:54329 -- go run .
```

Then, in a second terminal:

```sh
go run ./cmd/traffic http://localhost:4143
```
