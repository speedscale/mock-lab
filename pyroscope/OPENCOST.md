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
- an agent that supports STDIO and Streamable HTTP MCP servers; the examples
  below use Codex
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

From this directory, add the two servers used by this guide to Codex:

```shell
codex mcp add proxymock -- proxymock mcp run --work-dir .
codex mcp add opencost --url http://127.0.0.1:18081/
codex mcp list
```

Other agents can translate the same entries from `mcp.example.json`.
OpenCost uses Streamable HTTP and proxymock uses STDIO. Keep
`make opencost-forward` running while OpenCost MCP is in use. Grafana is used
by the main Pyroscope guide, not by this allocation comparison.

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

Paste this task into Codex:

```text
Read proxymock/results/opencost/baseline/load/window.json yourself.
Programmatically construct the window argument as file.start + "," + file.end
and pass it directly to OpenCost MCP get_allocation_costs. Do not ask me to
copy, substitute, or confirm timestamps. Do not round or widen the interval.

aggregate: "namespace"
step: "1m"
accumulate: true

Select the catalog-api allocation and report start, end, cpuCost, ramCost,
and totalCost. In baseline/load/summary.json, select the endpoints entry
whose url and method both equal "-ALL-". Report requests.succeeded,
requests.failed, requests.per-second, and latency.p95 from its metrics object.
```

A successful response should have this shape:

```text
Queried exact window: 2026-08-11T18:19:00Z,2026-08-11T18:22:01Z

catalog-api allocation:

- start: 2026-08-11T18:19:00Z
- end: 2026-08-11T18:23:00Z
- cpuCost: 0.06666666666666667
- ramCost: 0.013333333333333334
- totalCost: 0.08

-ALL- / -ALL- endpoint metrics:

- requests.succeeded: 17132
- requests.failed: 0
- requests.per-second: 95.17747305599376
- latency.p95: 42
```

Your timestamps, costs, request count, throughput, and latency will vary. Check
that `Queried exact window` exactly matches `baseline/load/window.json`, that
the response includes the `catalog-api` allocation, and that the `-ALL-` metrics
show zero failed requests. OpenCost may align the allocation's returned `start`
and `end` to the configured one-minute step, as shown above; that does not
change the exact interval passed to the MCP tool.

If `catalog-api` is absent, wait one scrape interval and repeat the identical
tool call. Do not widen the window or substitute pod timestamps.

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

Paste this task into Codex:

```text
Call proxymock MCP response_diff with:
- baseline-directory: ["proxymock/results/opencost/baseline/functional"]
- in-directory: ["proxymock/results/opencost/candidate/functional"]

Report every stable-field difference. Matching status codes or schemas are
not proof of equivalence.

Read proxymock/results/opencost/candidate/load/window.json yourself.
Programmatically construct the window argument as file.start + "," + file.end
and pass it directly to OpenCost MCP get_allocation_costs with
aggregate="namespace", step="1m", and accumulate=true. Do not ask me for
timestamps. Select catalog-api and retain cpuCost, ramCost, and totalCost.
```

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

## Example of good AI output

The comparison response should contain a verdict, payload-level evidence, raw
costs and throughput, the normalized cost, and the exact windows used for each
OpenCost query. For example:

**Approved.**

The payload-level response diff found no stable-field differences. One volatile
field was correctly excluded as noise.

| Metric | Baseline | Candidate | Change |
| --- | ---: | ---: | ---: |
| Replay passed | Yes | Yes | — |
| Functional failures | 0 | 0 | 0 |
| Stable-field differences | — | 0 | 0 |
| Load p95 latency | 57 ms | 58 ms | +1 ms |
| Throughput | 98.6830 req/s | 96.9218 req/s | −1.78% |
| Load failures | 0 | 0 | 0 |
| `cpuCost` | 0.06666667 | 0.06666667 | 0 |
| `ramCost` | 0.01333333 | 0.00166667 | −87.50% |
| `totalCost` | 0.08000000 | 0.06833333 | −14.58% |
| Successful requests | 17,763 | 17,446 | −317 |
| `totalCost / requests.succeeded` | 0.000004503744 | 0.000003916848 | −13.03% |

OpenCost windows were constructed directly from each file:

- Baseline: `2026-08-12T00:06:00Z,2026-08-12T00:09:02Z`
- Candidate: `2026-08-12T00:17:00Z,2026-08-12T00:20:01Z`

Both replays passed, all functional and load failure counts are zero,
stable-field differences are zero, and cost per successful request decreased by
13.03%.

These measurements are directional rather than portable hardware guarantees.

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

## Pause, resume, or remove the lab

This section is not part of an uninterrupted demo run. Continue through the
comparison above, then perform only the final teardown below. Use pause and
resume only when leaving the experiment midway.

To pause, press Ctrl-C in the terminal running `make opencost-forward`. Then,
from the lab directory, run:

```shell
make opencost-stop
```

To resume, start or repair the cluster from the lab directory:

```shell
make opencost-up
```

In a second terminal, restart the forwarder:

```shell
make opencost-forward
```

`opencost-stop` pauses the lab containers, so `opencost-up` can normally
unpause them without rebuilding Kubernetes. If an older stopped or stale
profile cannot restart, minikube deletes and recreates only this isolated
profile. Startup then removes interrupted Helm releases, converges the pinned
stack, and restores the baseline allocation.

If a baseline measurement was interrupted, rerun the complete baseline block:

```shell
make opencost-deploy-baseline
make opencost-functional-baseline
make opencost-load-baseline
```

If a candidate measurement was interrupted, run this block instead:

```shell
make opencost-deploy-candidate
make opencost-functional-candidate
make opencost-load-candidate
```

Run only the block for the interrupted variant. A load result is complete only
when its `load/window.json` exists; never construct a window from partial
results or file timestamps.

After the final comparison, press Ctrl-C in the forwarding terminal. Then
remove the isolated cluster:

```shell
make opencost-down
```

This deletes only the minikube profile selected by `MINIKUBE_PROFILE` (default
`opencost-lab`). Recordings and replay evidence under `proxymock/` remain on
the host.
