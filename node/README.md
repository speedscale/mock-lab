# Node.js demo app

The Node.js version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Zero dependencies — built-in `http` + global `fetch`.

## Run

```shell
node index.js
```

## proxymock: record, mock, replay

```shell
proxymock record -- node index.js                 # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- node index.js                    # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

Node's HTTP stack does not read proxy env vars automatically. See the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/)
for the proxy/TLS setup `proxymock record` needs with Node.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
