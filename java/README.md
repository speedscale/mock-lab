# Java demo app

The Java version of the [mock-lab](../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF projects API downstream
(`DOWNSTREAM_URL`, default `https://demo-api-dev.trafficreplay.com`; set `PORT` to change the port).
Single file, run directly with JDK 11+ source-file mode — no build tool.

## Run

```shell
java App.java
```

## proxymock: record, mock, replay

```shell
proxymock record -- java App.java                 # record the downstream calls
../lab/tests/run_http_tests.sh --recording            # in a second terminal, drive traffic
proxymock mock -- java App.java                    # serve the downstream from the recording
proxymock replay --test-against http://localhost:8080
```

No extra config needed: when `proxymock record` wraps the JVM it injects `JAVA_TOOL_OPTIONS`
with the `-D` proxy flags and a CA truststore, so `java.net.http.HttpClient` routes through
proxymock automatically.

Endpoints and the API contract: see the [root README](../README.md) and [`openapi.yaml`](../lab/openapi.yaml).
