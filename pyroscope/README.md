# Pyroscope + proxymock agent debugging lab

This lab gives an AI coding agent two complementary forms of evidence for one
performance regression:

- Grafana Pyroscope shows where the Go process spends CPU time.
- proxymock supplies the exact large downstream response, replays the same
  inbound request, measures latency/throughput, and checks response semantics.

The application intentionally starts in the slow but functionally correct
state. The goal is for an agent to diagnose and fix it, not to guess from a
synthetic benchmark alone.

## Prerequisites

- Go 1.23 or newer
- Docker with Compose
- `proxymock` installed, activated, and available on `PATH`
- `curl` and `jq` for the optional direct API checks

All exposed services bind to localhost. Grafana uses `admin` / `admin` only for
this disposable local lab.

## 1. Start profiling

```shell
cd pyroscope
make observability-up
```

This starts pinned versions of Grafana, Pyroscope, and Alloy. Alloy pulls the
Go pprof endpoints from `localhost:6060`; Grafana is at
<http://localhost:3000>, with the Pyroscope datasource provisioned as UID
`pyroscope`.

## 2. Create the traffic contract

Start the deterministic catalog dependency:

```shell
make catalog
```

In a second terminal, start recording:

```shell
make record
```

In a third terminal, send one request through proxymock's inbound recording
port:

```shell
curl http://localhost:4143/api/catalog/stats
```

Stop `make record`. The recording now contains one inbound API exchange and its
outbound `/v1/catalog` exchange. The latter contains 15,120 records, including
duplicates and invalid entries. Those cases are deliberate: an optimization
that merely deletes validation or deduplication should fail the semantic check.

## 3. Run the baseline offline

The real catalog is no longer required after recording. Start the app with the
recorded downstream response and disable passthrough:

```shell
make mock
```

In another terminal, capture the functional baseline and then the sustained CPU
sample:

```shell
make functional-replay RESULTS_DIR=proxymock/results/baseline
make load-replay RESULTS_DIR=proxymock/results/baseline
```

The functional replay makes three requests so proxymock can learn that headers
such as `Date` are volatile. Load mode intentionally skips full response-match
scoring in exchange for high throughput; use it for performance evidence, not
correctness evidence.

Record the UTC start/end timestamps printed for the 45-second load. In Grafana,
open Profiles Drilldown and select `catalog-api` and the Process CPU profile for
that exact window.

## 4. Connect an AI coding agent

Copy `mcp.example.json` into the MCP configuration format your agent supports,
or translate its two server entries. Start the agent with this directory as its
working directory so proxymock resolves `--work-dir .` correctly.

The Grafana MCP container is pinned and read-only. It exposes only datasource,
Pyroscope, and navigation tools. The basic credentials are appropriate only for
this localhost lab; use a least-privilege Grafana service-account token outside
it.

Give the agent [AGENT_TASK.md](AGENT_TASK.md). A useful investigation sequence
is:

1. `list_datasources` and `list_pyroscope_profile_types`.
2. `query_pyroscope` with datasource `pyroscope`, Process CPU, matcher
   `{service_name="catalog-api"}`, and the exact baseline interval.
3. proxymock `search_local_traffic` over `proxymock/recording` to inspect input
   shape and response invariants.
4. Change the code and run tests.
5. Re-run functional replay to `proxymock/results/candidate` and call proxymock
   `response_diff` with baseline `proxymock/results/baseline/functional`.
6. Re-run load replay to `proxymock/results/candidate`, then query Pyroscope for
   that exact candidate interval.

## 5. Acceptance criteria

- Unit tests pass.
- Functional replay reports no failed requests.
- `response_diff` reports no stable-field differences.
- The same 8-VU load replay has materially lower latency and higher throughput.
- The original application hotspot is absent or greatly reduced in the new CPU
  profile; the cost should move to unavoidable work such as JSON decoding.

Do not compare only normalized flamegraph widths: changing throughput changes
the amount of work sampled. Use proxymock for absolute latency/throughput and
Pyroscope for source-level attribution.

## Validated reference run

The stack and both MCP servers were exercised end to end on Apple arm64. The
intended fix was applied temporarily, measured, checked, and then removed so the
repository remains a genuine agent task.

| Evidence | Baseline | Correct candidate |
| --- | ---: | ---: |
| Core benchmark | 83.9 ms/op | 0.69 ms/op |
| 8-VU replay average latency | 168.2 ms | 13.0 ms |
| 8-VU replay throughput | 47.3 req/s | 591.3 req/s |
| Functional response diff | baseline | no stable-field differences |
| CPU attribution | deduplication and string equality dominate | JSON decoding dominates |

The results are directional, not universal hardware guarantees. Re-run both
intervals on the same machine and compare those measurements.
