# PHP demo app

The PHP version of the [mock-lab](../../README.md) proxymock demo. It serves an HTTP API on
`:8080` and fulfills each request by calling the CNCF downstream API
(`DOWNSTREAM_URL`, default `https://demo-api.trafficreplay.com`; set `PORT` to change the port).
Needs PHP 8.1+ with the `curl` extension (Homebrew `php`, `php-cli` + `php-curl` on Debian/Ubuntu;
preinstalled in the devcontainer).

## Run

```shell
php app.php
```

## proxymock: record, mock, replay

> First time only: install proxymock and run `proxymock init --api-key <key>` once (free key at [app.speedscale.com/signup](https://app.speedscale.com/signup)). In a Codespace the CLI is preinstalled.

```shell
proxymock record -- php app.php                  # 1. record the downstream calls
../../lab/tests/run_tests.sh --recording            # 2. second terminal: drive every endpoint
proxymock web                                    # 3. browse the recorded traffic (:7788)
proxymock mock -- php app.php                     # 4. serve the downstream from the recording
proxymock replay --test-against http://localhost:8080   # 5. replay (or use Replay in proxymock web)
```

`proxymock record` exports the proxy and TLS settings. PHP's curl extension is libcurl, so
`HTTP_PROXY`/`HTTPS_PROXY` are honored, but — like C++ — libcurl does **not** read
`SSL_CERT_FILE`. The app sets `CURLOPT_CAINFO` from that env var, and also sets
`CURLOPT_PROXY` from it so a PHP build that disabled libcurl's env proxy still records.
Without the CAINFO wiring, the downstream HTTPS call through proxymock fails verification.

## Auth flow (two moving IDs)

This app also serves `POST /oauth/token`, `POST /api/orders` (Bearer-protected, validates the project against the downstream), and `GET /api/orders/{order_id}` (Bearer-protected). The `access_token` and `order_id` are generated fresh on every call. The quickstart's `../../lab/tests/run_tests.sh` drives this flow too. On replay those two IDs are stale, so a committed *smart replace* blueprint re-chains them — see the [root README](../../README.md#auth-handshake--the-two-moving-ids) and [`../../lab/proxymock/`](../../lab/proxymock/) for the ready-to-run recording + blueprint.

Endpoints and the API contract: see the [root README](../../README.md) and [`openapi.yaml`](../../lab/openapi.yaml).
