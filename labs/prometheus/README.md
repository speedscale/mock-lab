# Prometheus + proxymock non-CPU latency lab

This lab demonstrates a p95 latency regression that a CPU profile cannot
explain. The checkout API answers `GET /api/quote` by calling a pricing
dependency that takes a fixed 40 ms. The API's pricing HTTP client carries a
deliberate two-connection budget, so eight concurrent virtual users queue
behind connection acquisition: p95 climbs to roughly 4x the dependency time
while the process stays almost idle. Prometheus histograms separate the
symptom (request duration) from the cause (connection wait) and rule out
compute (CPU seconds). proxymock supplies the identical 1,200-request workload
for the baseline and the candidate, and proves the response contract did not
change.

The lab is intentionally checked in with the bottlenecked implementation. An
agent should read the metrics, find the queueing, make the smallest fix, and
prove behavior stayed stable.

## Prerequisites

- Docker with Compose
- Go 1.23 or newer, `curl`, and `jq`
- proxymock 2.5.842 or newer, installed, initialized, and on `PATH`
- An MCP client with STDIO support; the examples use Codex

Run every command below from this `prometheus` directory of your `mock-lab`
clone.

The lab pins Prometheus 3.12.0, Grafana 13.1.0, Grafana MCP 0.14.0, and
`prometheus/client_golang` 1.20.5. Grafana binds to `127.0.0.1:3003` and
Prometheus to `127.0.0.1:9091` because the other reference labs in this
repository use the neighboring ports.

Prometheus scrapes the host-side checkout process every second. That interval
keeps short replay windows measurable in a lab; production systems normally
scrape far less often.

## 1. Start Prometheus and Grafana

```shell
make up
```

Grafana is at `http://127.0.0.1:3003` with disposable `admin` / `admin`
credentials. Prometheus is at `http://127.0.0.1:9091`.

## 2. Record the request and its dependency boundary

```shell
make capture RECORDING_DIR=proxymock/recording
```

The capture target starts the pricing fixture and the checkout API under
`proxymock record`, sends one `GET /api/quote?sku=SSC-4110&qty=3` through the
inbound reverse proxy, and stops cleanly. The recording holds one inbound
RRPair and one outbound `GET /v1/price/SSC-4110` RRPair.

proxymock's local HTTP capture stores the dependency response time at 1 ms
precision in this environment, so `make mock` applies a pinned `40x` timing
multiplier. This keeps the offline mock's per-call duration equal to the
fixture's real 40 ms delay, which is what makes the connection queueing
reproducible without the fixture running.

## 3. Replay the baseline and save exact UTC intervals

Start the API against the recorded dependency; the pricing fixture is no
longer needed:

```shell
make mock RECORDING_DIR=proxymock/recording
```

Wait for proxymock to print `mocking traffic sent from your app`. In another
terminal:

```shell
make functional-replay RESULTS_DIR=proxymock/results/baseline
make load-replay RESULTS_DIR=proxymock/results/baseline
make verify RESULTS_DIR=proxymock/results/baseline
```

Functional mode repeats the request three times and requires zero failed
requests and a 100% stable response match. Load mode runs only after that gate
and sends 150 iterations from each of eight virtual users; a fixed iteration
count keeps the baseline and candidate workloads identical and prevents
end-of-duration in-flight requests from being counted as harness timeouts.

Each successful replay records nanosecond UTC boundaries and publishes a
conservative whole-second query interval to its `window.json`:

```text
proxymock/results/baseline/load/window.json
```

The `mkwindow` helper floors `query_start`, ceilings `query_end` past the last
1-second scrape, and precomputes `window_seconds`, so every Grafana MCP call
receives whole-second RFC3339 values and a ready-made PromQL range; the agent
passes those fields unchanged. Nobody records, copies, rounds, substitutes, or
confirms a timestamp by hand.

## 4. Connect Grafana and proxymock MCP

```shell
codex mcp add proxymock -- proxymock mcp run \
  --work-dir "$PWD"
codex mcp add grafana -- docker run --rm -i \
  --add-host host.docker.internal:host-gateway \
  -e GRAFANA_URL=http://host.docker.internal:3003 \
  -e GRAFANA_USERNAME=admin \
  -e GRAFANA_PASSWORD=admin \
  grafana/mcp-grafana:0.14.0 -t stdio --disable-write \
  --enabled-tools datasource,prometheus,navigation
codex mcp list
```

`mcp.example.json` contains the equivalent configuration. Give the agent
`AGENT_TASK.md`. It names the actual Grafana MCP Prometheus tools and the four
instant queries that separate symptom, cause, and compute over the exact
replay interval.

## 5. Make and test the smallest fix

The intended change raises the pricing client's connection budget in
`internal/checkout/checkout.go` so eight concurrent requests no longer queue
behind two connections. It does not change request validation, response
values, the metrics, the fixture, or any replay parameter.

After the agent edits the code, stop the baseline `make mock`, start it again
so it rebuilds the candidate, and repeat both evidence paths:

```shell
make functional-replay RESULTS_DIR=proxymock/results/candidate
make load-replay RESULTS_DIR=proxymock/results/candidate
make verify RESULTS_DIR=proxymock/results/candidate
```

Then call proxymock MCP `response_diff` exactly as `AGENT_TASK.md` shows and
repeat the Prometheus queries over the candidate's own `window.json`.

## Validated reference evidence

The complete workflow was run locally on Apple arm64. Both query intervals
came directly from their `window.json` files and were passed unchanged to
Grafana MCP 0.14.0. [`evidence/reference.json`](evidence/reference.json)
retains the exact windows, unrounded metrics, and comparison results in one
machine-readable record. These values are an example from one machine, not a
golden performance threshold.

| Evidence | Baseline | Candidate |
| --- | ---: | ---: |
| Pricing connection budget | 2 | 16 |
| Functional failed requests | 0 | 0 |
| Functional result match | 100% | 100% |
| Stable-field response differences | N/A (comparison source) | 0 (none) |
| Load requests (identical workload) | 1,200 | 1,200 |
| Load failed requests | 0 | 0 |
| Load p95 latency | 173 ms | 46 ms |
| Load throughput | 46.4 req/s | 176.8 req/s |
| Prometheus p95 request duration | 190 ms | 49 ms |
| Prometheus p95 connection wait | 140 ms | 0.99 ms |
| Prometheus average CPU cores | 0.05 | 0.10 |

The connection wait explains the baseline p95: waiting for one of two pooled
connections accounts for roughly three quarters of the p95 request duration,
while the process averages five percent of one core. The candidate improves
the causal metric and the p95 under the identical workload, with zero failed
requests and zero stable-field response differences.

## Measurement boundaries

- Prometheus histograms are aggregatable: p95 comes from `histogram_quantile`
  over summed `le` buckets, never from averaging client-side quantiles.
  Bucket boundaries quantize the estimate, which is why the table reports
  190 ms rather than an exact sample.
- `increase()` extrapolates counter deltas to the range boundaries, so its
  request counts are a magnitude cross-check. The exact count, 1,200, comes
  from the proxymock load summary.
- The connection-wait histogram observes `httptrace` `GetConn` to `GotConn`
  time. It measures pool acquisition, not server think time or TCP handshakes.
- A local 40 ms fixture delay is deterministic evidence, not a production
  latency model. Replay measurements are directional and machine-specific.
- proxymock validates payload behavior and supplies aggregate latency and
  throughput. Load mode skips response scoring; the three-request functional
  replay plus `response_diff` is the behavior gate.
- Raising a connection budget trades queueing for concurrency against the
  dependency. Production fixes must confirm the dependency can absorb the
  extra parallel connections before removing a protective limit.

## Primary references

- [proxymock MCP quickstart](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-mcp/)
- [Prometheus histograms and summaries](https://prometheus.io/docs/practices/histograms/)
- [PromQL histogram_quantile](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile)
- [Prometheus instant and range queries](https://prometheus.io/docs/prometheus/latest/querying/api/#instant-queries)
- [Go net/http Transport connection limits](https://pkg.go.dev/net/http#Transport)
- [Go net/http/httptrace](https://pkg.go.dev/net/http/httptrace)
- [Grafana MCP tools](https://grafana.com/docs/grafana/latest/developer-resources/mcp/reference/mcp-tools-table/)

When finished, stop `make mock` with Ctrl-C and remove only this lab's Compose
stack:

```shell
make down
```
