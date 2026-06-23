# Go demo app

The Go version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).

## Run

```shell
go run .
```

## proxymock: record, mock, replay

```shell
proxymock record -- go run .                      # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- go run .                         # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

`proxymock record` exports the proxy and TLS settings to the child process, and Go's
`net/http` picks them up automatically — no extra configuration.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
