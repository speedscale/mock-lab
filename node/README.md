# Node.js demo app

The Node.js version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Zero dependencies — built-in `http` + global `fetch`. Needs **Node 24+** (or 22.21+) for the
built-in proxy support proxymock relies on; the devcontainer ships Node 24.

## Run

```shell
node index.js
```

## proxymock: record, mock, replay

```shell
# Node's fetch ignores proxy env vars on its own. Turn on the built-in proxy support and
# trust proxymock's TLS CA — needed for both record and mock (not for replay):
export NODE_USE_ENV_PROXY=1
export NODE_EXTRA_CA_CERTS="$HOME/.speedscale/certs/tls.crt"

proxymock record -- node index.js                 # record the downstream calls
../lab/tests/run_http_tests.sh --recording        # in a second terminal, drive traffic
proxymock mock -- node index.js                   # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

Unlike the other languages, Node's `fetch` does not honor `http_proxy`/`https_proxy` by itself.
Node 24 (backported to 22.21) adds `NODE_USE_ENV_PROXY`, which routes `fetch` through proxymock;
`NODE_EXTRA_CA_CERTS` points Node at proxymock's CA so the recorded HTTPS call validates. On
older Node, route `fetch` through a proxy dispatcher per the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
