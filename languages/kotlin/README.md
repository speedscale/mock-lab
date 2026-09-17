# Kotlin demo app

The Kotlin version of the [mock-lab](../../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF downstream API
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).
Single file, no Gradle — compile with `kotlinc` and run the jar on JDK 17+. Kotlin is a
JVM language, so proxymock uses the **same SOCKS proxy and JKS truststore as Java**, not a
separate capture path. Needs the Kotlin compiler (preinstalled in the devcontainer; `brew install
kotlin` or the [compiler zip](https://github.com/JetBrains/kotlin/releases) otherwise).

## Run

```shell
kotlinc App.kt -include-runtime -d app.jar && java -jar app.jar
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
# Kotlin's JVM HTTP client ignores HTTP_PROXY/HTTPS_PROXY, same as Java. Point
# the JVM at proxymock's SOCKS proxy and trust the proxymock CA — needed for
# both record and mock (not for replay).
# First time only, with JAVA_HOME set: proxymock admin certs --jks
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} \
  -DsocksProxyHost=localhost -DsocksProxyPort=4140 -DsocksProxyVersion=5 \
  -Djavax.net.ssl.trustStore=$HOME/.speedscale/certs/cacerts.jks \
  -Djavax.net.ssl.trustStorePassword=changeit"

kotlinc App.kt -include-runtime -d app.jar
proxymock record -- java -jar app.jar            # 1. record the downstream calls
../../lab/tests/run_tests.sh --recording            # 2. second terminal: drive every endpoint
proxymock web                                    # 3. browse the recorded traffic (:7788)
proxymock mock -- java -jar app.jar               # 4. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 5. replay (or use Replay in proxymock web)
```

This is the Java setup with a Kotlin main. `-DsocksProxyHost` / `-DsocksProxyPort` route
`java.net.http.HttpClient` through proxymock; the truststore flags point the JVM at
proxymock's CA (`proxymock admin certs --jks`, needs `JAVA_HOME`). For an IDE, put the same
`-D` arguments in the application's VM options. See
[languages/java/README.md](../java/README.md) and the
[language reference](https://docs.speedscale.com/proxymock/getting-started/language-reference/).

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. The quickstart's `../../lab/tests/run_tests.sh` drives this flow too. On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see the [root README](../../README.md#auth-handshake--the-two-moving-ids) and [`../../lab/proxymock/`](../../lab/proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../../README.md) and [`openapi.yaml`](../../lab/openapi.yaml).
