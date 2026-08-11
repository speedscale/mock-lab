# Tempo + proxymock serial dependency-call lab

One catalog request carries eight product IDs. The baseline API fetches those
eight inventory records one at a time. Tempo makes the serial waterfall
visible; proxymock preserves the exact input and dependency exchanges that
explain why the waterfall exists.

The lab is intentionally checked in with the correct-but-serial implementation.
An agent should inspect both evidence sources, add bounded concurrency, and then
prove that behavior stayed stable.

## Prerequisites

- Go 1.23 or newer
- Docker with Compose
- proxymock 2.5.857 or newer, installed, initialized, and on `PATH`
- `curl` and `jq`
- An MCP client with STDIO support; the commands below use Codex

The tested stack is pinned to Tempo 2.10.0, Grafana 13.1.0, Grafana MCP 0.14.0,
OpenTelemetry Go 1.37.0, and `otelhttp` 0.62.0. The reference candidate pins
`x/sync` 0.16.0. Grafana binds to `127.0.0.1:3001` because the Pyroscope
reference lab uses port 3000.

Install and initialize proxymock:

```shell
brew install speedscale/tap/proxymock
proxymock init
proxymock version
```

## 1. Start Tempo and record the causal input

```shell
cd /Users/matthewleray/s2/mock-lab/tempo
make observability-up
make inventory
```

In a second terminal:

```shell
cd /Users/matthewleray/s2/mock-lab/tempo
make record RECORDING_DIR=proxymock/recording
```

In a third terminal, send the one fixture through proxymock's inbound port:

```shell
cd /Users/matthewleray/s2/mock-lab/tempo
curl -H 'Content-Type: application/json' \
  --data @fixtures/catalog-request.json \
  http://localhost:4143/api/catalog
```

Stop `make record`, then stop `make inventory`. The recording should contain
one inbound `POST /api/catalog` and eight outbound inventory GETs:

```shell
find proxymock/recording -type f -name '*.md'
```

The dependency fixture deliberately sleeps for 35 ms. proxymock's HTTP capture
stores that local response at 1 ms precision in this environment, so `make
mock` applies a pinned `35x` timing multiplier. This keeps the offline mock's
per-call duration close to the recorded wall-clock delay and makes the serial
critical path deterministic.

## 2. Replay the baseline and save exact UTC intervals

Start the API against the recorded dependencies; the real inventory service is
no longer needed:

```shell
make mock RECORDING_DIR=proxymock/recording
```

In another terminal:

```shell
make functional-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/baseline
make load-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/baseline
```

Each target records its own UTC start and end with nanosecond precision and
publishes the window only after proxymock exits successfully:

```text
proxymock/results/baseline/functional/window.json
proxymock/results/baseline/load/window.json
```

The corresponding `summary.json` files contain machine-readable request,
latency, and throughput metrics. Functional mode repeats the request three
times and scores response behavior. Load mode runs four VUs for 30 seconds and
does not score response bodies; never use the load result as correctness proof.

## 3. Configure the two MCP servers

From this directory, add the local proxymock MCP server and the pinned,
read-only Grafana MCP server:

```shell
codex mcp add proxymock -- proxymock mcp run --work-dir /Users/matthewleray/s2/mock-lab/tempo
codex mcp add grafana -- docker run --rm -i \
  --add-host host.docker.internal:host-gateway \
  -e GRAFANA_URL=http://host.docker.internal:3001 \
  -e GRAFANA_USERNAME=admin \
  -e GRAFANA_PASSWORD=admin \
  grafana/mcp-grafana:0.14.0 -t stdio --disable-write \
  --enabled-tools datasource,navigation
codex mcp list
```

`mcp.example.json` contains the equivalent client configuration. Tempo's
embedded MCP server is enabled in `config/tempo.yaml`. Grafana MCP discovers it
through the provisioned datasource and exposes the real proxied tool names
`tempo_traceql-search` and `tempo_get-trace`. Proxied tools remain enabled even
though the static tool list is limited to datasource and navigation tools.

Give the agent [AGENT_TASK.md](AGENT_TASK.md). Its first prompt uses these exact
calls and requires the agent to parse `window.json` itself:

```text
list_datasources
{"type":"tempo","limit":50,"offset":0}

tempo_traceql-search
{"datasourceUid":"tempo","query":"{ resource.service.name = \"catalog-api\" && name = \"POST /api/catalog\" }","start":file.start,"end":file.end}

tempo_get-trace
{"datasourceUid":"tempo","trace_id":the returned traceID}
```

Do not copy timestamps into the prompt. Do not widen the interval for ingestion
lag. If no trace is returned, wait briefly and repeat the identical MCP call
with the values already parsed from the file.

Before any edit, proxymock MCP should find one inbound body with eight IDs and
eight outbound `/v1/inventory/{productID}` calls. Their timestamps advance one
dependency delay at a time. Tempo should show the same fact as eight
`inventory.lookup` spans and eight `GET inventory` client spans with no overlap.

## 4. Make and test the smallest fix

The intended change uses a bounded group of four dependency calls and writes
each result back to its input index. It does not change request validation,
hard-code fixture values, reorder output, or relax error handling.

Pin the candidate's only new dependency before editing:

```shell
go get golang.org/x/sync@v0.16.0
```

After the agent edits the code:

```shell
make test
```

Stop the baseline `make mock`, start it again so it builds the candidate, and
repeat both evidence paths:

```shell
make mock RECORDING_DIR=proxymock/recording
```

In another terminal:

```shell
make functional-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/candidate
make load-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/candidate
```

Then call proxymock MCP `response_diff` exactly as shown in `AGENT_TASK.md` and
query the candidate trace by parsing
`proxymock/results/candidate/functional/window.json`. Matching status codes or
schemas do not satisfy the contract; report every stable-field difference.

## Validated reference evidence

The complete workflow was run locally on Apple arm64. Both trace intervals came
directly from their functional `window.json` files and were passed unchanged to
Grafana MCP 0.14.0. The selected trace in each interval was the longest of the
three functional requests. [`reference-evidence.json`](reference-evidence.json)
retains the exact replay windows, unrounded metrics, trace facts, attribution,
and proxymock comparison result in one machine-readable record.

| Evidence | Baseline | Bounded-concurrency candidate |
| --- | ---: | ---: |
| Functional failed requests | 0 | 0 |
| Functional result match | 100% | 100% |
| Stable-field response differences | N/A (comparison source) | 0 (none) |
| Functional average latency | 301 ms | 80 ms |
| 4-VU load average latency | 303 ms | 80 ms |
| 4-VU load throughput | 13.07 req/s | 49.33 req/s |
| Load failed requests | 0 | 0 |
| Trace ID | `72ab046d4903da9b9cbf417c6ee51227` | `2b51700da7a9b62bfb8c2cc974649b07` |
| Total span count | 17 | 17 |
| `inventory.lookup` spans | 8 | 8 |
| `GET inventory` client spans | 8 | 8 |
| Downstream fan-out | 8 | 8 |
| Dependency trace shape | 8 serial calls | 2 waves of 4 calls |
| Root critical path | 301.876 ms | 85.073 ms |
| Source attribution | `catalog-api`; `internal/catalog/catalog.go`; `catalog.(*Service).fetchInventory` | same |

proxymock `response_diff` compared the paired functional response, filtered two
learned volatile fields, and reported no stable-field differences. The change
kept the same number of dependency calls but removed the serial pattern: the
critical path fell 71.8%, while load throughput increased 3.78x in this run.

## Measurement limitations

- This is a local directional comparison, not a production capacity claim.
  Re-run both variants on the same machine.
- The mock timing multiplier compensates for millisecond quantization in this
  local capture. It models a stable dependency delay; it does not model network
  jitter, connection-pool limits, rate limiting, or tail latency.
- The offline trace contains the catalog server span, eight application spans,
  and eight HTTP client spans. It does not contain inventory server spans
  because proxymock replaces that service during replay.
- Span count and fan-out stay at 17 and 8. Concurrency fixes serial critical
  path, but batching would be required to reduce the number of dependency calls.
- The trace critical path is the root server-span duration for one selected
  functional request. proxymock load summaries supply aggregate latency and
  throughput; one trace is not a percentile.
- Load mode skips response scoring for throughput. The three-request functional
  replay plus `response_diff` is the behavior gate.

## Primary references

- [proxymock CLI quickstart](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-cli/)
- [proxymock MCP tools](https://docs.speedscale.com/proxymock/how-it-works/mcp-tools/)
- [Tempo MCP server](https://grafana.com/docs/tempo/latest/api_docs/mcp-server/)
- [Grafana MCP proxied tools](https://grafana.com/docs/grafana/latest/developer-resources/mcp/configure/proxied-tools/)
- [Tempo datasource configuration](https://grafana.com/docs/grafana/latest/datasources/tempo/configure-tempo-data-source/)
- [TraceQL query editor and syntax](https://grafana.com/docs/grafana/latest/datasources/tempo/query-editor/)
- [OpenTelemetry Go instrumentation libraries](https://opentelemetry.io/docs/languages/go/libraries/)

When finished, stop the mock process and remove only this lab's Compose stack:

```shell
make observability-down
```
