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
- **`vendor-capture/`** — a deliberately drifted copy of the five downstream pairs in
  `proxymock/recording`, standing in for a capture taken after the vendor shipped an API
  update. See [Vendor capture](#vendor-capture).

## Vendor capture

[`vendor-capture`](vendor-capture) is not a third kind of recording. Two responses were edited
to break [`openapi.yaml`](openapi.yaml): one `GET /v1/categories` element reports `count` as a
string, and one of the two `GET /v1/project/kubernetes` pairs drops the required `maturity`
field while the other keeps it, so the capture contradicts itself on the same endpoint minutes
apart. It exists to demo contract testing:

```shell
# from the repo root — exits 2 with 3 conformant and 2 violating
proxymock validate --spec lab/openapi.yaml --in lab/vendor-capture/demo-api.trafficreplay.com

# the clean recording still exits 0 with 5 conformant
proxymock validate --spec lab/openapi.yaml --in lab/proxymock/recording/demo-api.trafficreplay.com
```

`lab/proxymock/recording` remains the clean one and is what every skill proof and replay
example uses; nothing mocks or replays the vendor capture.
