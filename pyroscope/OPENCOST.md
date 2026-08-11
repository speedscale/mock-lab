# OpenCost + proxymock allocation lab

This companion lab answers a narrow question with two independent forms of
evidence:

- proxymock proves that the same recorded catalog traffic still returns the
  same stable values and remains inside the latency/error SLO.
- OpenCost measures the Kubernetes allocation over that replay's exact UTC
  interval so cost can be normalized per successful request.

The baseline reserves 1 CPU and 2 GiB for `catalog-api`. The candidate keeps
the 1 CPU capacity required by the replay and reduces the memory reservation to
256 MiB. Both run the same locally built image, the same deterministic catalog
fixture, and the same recording. This is a right-sizing exercise, not an
application-code optimization.

## Prerequisites

- Docker Desktop or another running Docker engine
- minikube 1.37 or newer with the Docker driver
- kubectl and Helm
- proxymock, activated and available on `PATH`
- curl and jq
- the recording and validated CPU candidate created by completing the main
  [Pyroscope guide](README.md) through its final replay-and-profile step

Keep that optimized candidate in your working tree while running this companion
lab. The repository defaults to the intentionally slow implementation so the
Pyroscope exercise remains reproducible; this guide then tests Kubernetes
right-sizing without making another application-code change.

The automation targets only the Kubernetes context and minikube profile named
`opencost-lab`. Commands never use an unqualified current context. The stack
uses pinned Prometheus and OpenCost charts and deterministic local prices:
$1 per CPU core-hour, $0.10 per GiB-hour, and zero storage/network cost.

## 1. Start the local cost stack

From this directory:

```shell
make opencost-up
```

This creates or converges an isolated minikube profile, installs Prometheus
chart 29.23.1 and OpenCost chart 2.5.29, builds the catalog image with Docker,
loads it into minikube, and deploys the baseline allocation. It does not modify
another Kubernetes cluster.

Keep the local endpoints open in a second terminal:

```shell
make opencost-forward
```

The helper reconnects automatically when applying an allocation replaces the
catalog pod, so the same local URL remains usable across both runs.

The forwarded endpoints are:

| Service | Local endpoint |
| --- | --- |
| catalog API | `http://127.0.0.1:18080` |
| OpenCost API | `http://127.0.0.1:19003` |
| OpenCost MCP | `http://127.0.0.1:18081/` |

Copy `mcp.example.json` into the MCP configuration format supported by your
agent, or translate its entries. OpenCost uses Streamable HTTP; proxymock and
Grafana use the transports already described in the main guide.

## 2. Measure the baseline allocation

Apply the baseline explicitly, then prove response behavior:

```shell
make opencost-deploy-baseline
make opencost-functional-baseline
```

The functional replay runs every recorded inbound request three times and
fails if any request fails or any stable response value stops matching. Keep
the resulting directory; it is the independent contract for the candidate:

```text
proxymock/results/opencost/baseline/functional
```

Repeating a replay replaces that variant's generated result directory so an
old run cannot be mistaken for part of the current evidence.

Now run the measured load:

```shell
make opencost-load-baseline
```

The command waits two minutes for complete Prometheus samples, starts on a UTC
minute boundary, runs two virtual users for three minutes, and publishes
`baseline/load/window.json` only if there are zero failed requests and p95
latency is at most 250 ms. The exact request summary is beside it in
`summary.json`.

Through OpenCost MCP, call `get_allocation_costs` with:

- `window`: the exact comma-separated `start,end` from `window.json`
- `aggregate`: `namespace`
- `resolution`: `1m`

Read the `catalog-api` allocation and retain its raw `totalCost`. If the
namespace is absent, Prometheus has not completed ingestion. Wait one scrape
interval and repeat the identical query; do not widen the window or substitute
pod timestamps.

The optional API companion saves the same exact-window allocation beside the
replay evidence and retries ingestion without changing the interval:

```shell
make opencost-query-baseline
```

## 3. Measure the candidate allocation

Change only the resource allocation and repeat the same evidence loop:

```shell
make opencost-deploy-candidate
make opencost-functional-candidate
make opencost-load-candidate
```

Through proxymock MCP, call `response_diff` with:

- baseline: `proxymock/results/opencost/baseline/functional`
- candidate: `proxymock/results/opencost/candidate/functional`

Report every stable-field difference. Matching HTTP status codes or response
schemas are not proof of equivalence.

Then query OpenCost MCP over the candidate's exact
`candidate/load/window.json` interval using the same allocation arguments as
the baseline.

Save the API companion evidence as well:

```shell
make opencost-query-candidate
```

## 4. Normalize and decide

For each allocation, calculate:

```text
allocation cost per successful request = catalog-api totalCost / requests.succeeded
```

Keep the numerator and denominator in the report; a normalized number without
its raw evidence is not auditable. Compare at least these fields:

| Evidence | Baseline | Candidate |
| --- | ---: | ---: |
| Failed functional requests |  |  |
| Stable response differences |  |  |
| Load p95 latency |  |  |
| Load throughput |  |  |
| Failed load requests |  |  |
| Exact UTC window |  |  |
| `catalog-api` allocation cost |  |  |
| Successful load requests |  |  |
| Allocation cost / successful request |  |  |

The candidate is valid only when it has no failed functional requests, no
stable response changes, no failed load requests, p95 latency at or below
250 ms, and lower allocation cost per successful request.

After `response_diff`, pass its stable-difference count to the comparison
generator. It refuses to assume that matching status codes imply zero changes:

```shell
STABLE_RESPONSE_DIFFERENCES=0 make opencost-compare
```

The command writes both JSON and Markdown comparisons under
`proxymock/results/opencost/` and emits an explicit candidate-valid verdict.

## Validated local run

The complete workflow was exercised on Apple arm64 with Docker Desktop and the
pinned chart versions in this guide.

| Evidence | Baseline | Candidate |
| --- | ---: | ---: |
| Failed functional requests | 0 | 0 |
| Stable response differences | baseline | 0 |
| Load p95 latency | 54 ms | 52 ms |
| Load throughput | 94.5 req/s | 98.8 req/s |
| Failed load requests | 0 | 0 |
| Allocation cost | 0.06000 | 0.05125 |
| Successful requests | 17,019 | 17,785 |
| Cost / successful request | 0.0000035255 | 0.0000028816 |

The candidate passed every gate and reduced allocation cost per successful
request by 18.3% in this run. These measurements are directional rather than
portable hardware guarantees.

An earlier candidate cut CPU to 500 millicores as well as memory. It still met
the loose 250 ms latency SLO, but throughput fell from 99.0 to 41.7 requests/s;
normalized cost rose 18.6%. The workflow rejected that cheaper-looking
allocation and preserved the CPU capacity in the final candidate. This is why
the denominator and throughput belong beside the cost number.

## Measurement boundaries

This lab measures requested Kubernetes allocation under fixed local prices.
It does not include a cloud provider's discounts, idle-sharing policy,
commitments, node bin-packing, or network/storage charges. Because Prometheus
samples at one-minute resolution, the warm-up and multi-minute windows are part
of the method, not optional waiting. Do not turn the percentage difference from
this local run into a production savings claim. See OpenCost's
[allocation API documentation](https://opencost.io/docs/integrations/api/) for
the window and resolution behavior.

When finished, `make opencost-down` deletes only the minikube profile named by
`MINIKUBE_PROFILE` (default `opencost-lab`).
