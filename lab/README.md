# lab/ — what the lab needs for itself

These are **not** language demos, and you don't run them for the quickstart. They exist to
support the demo apps and CI:

- **`server/`** — the reference implementation of the downstream CNCF API
  (`demo-api.trafficreplay.com`). CI and local runs use it as a **hermetic mock backend** so
  the demo apps can be exercised with no internet, and it generates the static dataset that is
  deployed to S3 behind CloudFront.
  - `cd server && go run .` — serve the API locally on `:8090`
  - `cd server && go run . -export ../static` — render the static file tree for S3
- **`tests/run_tests.sh`** — drives a running demo app's whole API (the 5 read endpoints plus
  the OAuth + order flow). In the proxymock flow this recorded traffic becomes the replay test
  suite; it's also the CI smoke test (which asserts the data). Run it from the repo root:
  `./lab/tests/run_tests.sh` (`--recording` to hit proxymock's inbound proxy, `DELAY=0` to skip
  the ~1s pause between calls).
- **`proxymock/`** — a committed recording + smart-replace blueprint, so `proxymock mock`/`replay`
  work offline against any language (`proxymock replay --in lab/proxymock/recording …`).
- **`openapi.yaml`** — the contract for the downstream API.
