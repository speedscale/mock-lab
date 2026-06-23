# lab/ — what the lab needs for itself

These are **not** language demos, and you don't run them for the quickstart. They exist to
support the demo apps and CI:

- **`server/`** — the reference implementation of the downstream CNCF API
  (`demo-api.trafficreplay.com`). CI and local runs use it as a **hermetic mock backend** so
  the demo apps can be exercised with no internet, and it generates the static dataset that is
  deployed to S3 behind CloudFront.
  - `cd server && go run .` — serve the API locally on `:8090`
  - `cd server && go run . -export ../static` — render the static file tree for S3
- **`tests/run_http_tests.sh`** — drives a running demo app's inbound endpoints. In the
  proxymock flow the recorded inbound traffic becomes the replay test suite; it's also the CI
  smoke test. Run it from the repo root: `./lab/tests/run_http_tests.sh`.
- **`openapi.yaml`** — the contract for the downstream API.
