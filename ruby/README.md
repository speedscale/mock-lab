# Ruby demo app

The Ruby version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Standard library only.

## Run

```shell
ruby app.rb
```

## proxymock: record, mock, replay

```shell
proxymock record -- ruby app.rb                   # record the downstream calls
../tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- ruby app.rb                      # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

Ruby's `Net::HTTP` reads the `http_proxy`/`https_proxy` env vars by default, so `proxymock record`
works with no extra configuration.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../openapi.yaml).
