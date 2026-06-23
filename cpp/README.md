# C++ demo app

The C++ version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` (POSIX sockets) and fulfills each request by calling the CNCF projects API downstream
via libcurl (`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).

Needs a C++17 compiler and **libcurl** (`libcurl4-openssl-dev` on Debian/Ubuntu; preinstalled in the devcontainer).

## Run

```shell
c++ -std=c++17 main.cpp -o app -lcurl
./app
```

## proxymock: record, mock, replay

```shell
c++ -std=c++17 main.cpp -o app -lcurl
proxymock record -- ./app                         # record the downstream calls
../tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- ./app                            # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

`proxymock record` exports the proxy and TLS settings, and libcurl picks them up
automatically — no extra configuration.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../openapi.yaml).
