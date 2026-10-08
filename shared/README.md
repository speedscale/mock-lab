# Shared tools

These tools support the language apps and the tutorial. The Go reference server and dashboard below are optional. Run the commands below from the repository root.

| Tool | Use |
| --- | --- |
| [server](server/) | Local reference implementation of the downstream CNCF projects API |
| [dashboard](dashboard/) | Browser controls for sending requests to a language app or proxymock's inbound proxy |
| [tests/run_tests.sh](tests/run_tests.sh) | Traffic driver and smoke test for the language apps, including OAuth and order calls |
| [openapi.yaml](openapi.yaml) | Contract for the downstream API |

Start the local downstream on port 8090:

```shell
(cd shared/server && go run .)
```

Point a language app at it with `DOWNSTREAM_URL=http://localhost:8090`. The tutorial uses `DEMO_API_URL=http://localhost:8090` instead. The server can also export static data with `go run . -export ../static`, run from `shared/server`.

Start the dashboard on port 8091:

```shell
(cd shared/dashboard && go run .)
```

Open http://127.0.0.1:8091. Choose App to send traffic to port 8080 or Record to send it to proxymock's inbound proxy on port 4143. Override the dashboard's port with `DASHBOARD_PORT`.

Drive the language app from another terminal:

```shell
./shared/tests/run_tests.sh
./shared/tests/run_tests.sh --recording
```

Use `DELAY=0` to skip the pause between calls. `PORT` overrides the target port.

Recordings and their companion documents live in the [root proxymock workspace](../proxymock/README.md) and each language's own workspace. The deliberately invalid vendor capture belongs to the [contract-testing lab](../labs/contract-testing/README.md).
