# .NET demo app

The .NET version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).

## Run

```shell
dotnet run
```

## proxymock: record, mock, replay

```shell
proxymock record -- dotnet run                    # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- dotnet run                        # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

`proxymock record` exports the proxy and TLS settings, and `HttpClient` picks them up
automatically — no extra configuration.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
