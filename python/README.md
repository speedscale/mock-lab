# Python demo app

The Python version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Standard library only.

## Run

```shell
python3 app.py
```

## proxymock: record, mock, replay

```shell
proxymock record -- python3 app.py                # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- python3 app.py                   # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

`proxymock record` exports the proxy and TLS settings, and `urllib` picks them up
automatically — no extra configuration.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
