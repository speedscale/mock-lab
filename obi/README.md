# OpenTelemetry eBPF Instrumentation + proxymock opaque-service lab

This lab reuses the repository's existing Go quickstart application and CNCF
catalog fixture without adding an OpenTelemetry SDK, agent, import, or source
tracepoint to either binary. OpenTelemetry eBPF Instrumentation (OBI, formerly
Grafana Beyla) observes their HTTP boundaries from the Linux kernel and Go
runtime. proxymock records the exact request and dependency exchange, then
replays it to prove the response contract independently of telemetry.

The deterministic fixture delays `GET /v1/projects` by 120 ms. One inbound
`GET /api/stats` therefore exposes a boundary-level bottleneck that OBI can
locate without application source access.

## Prerequisites

- Docker Desktop with at least 8 GiB assigned
- minikube 1.37 or newer with the Docker driver
- Kubernetes CLI 1.34 or newer and Helm 4
- Go 1.23 or newer, `curl`, and `jq`
- proxymock 2.5.857 or newer, installed, initialized, and on `PATH`
- An MCP client with STDIO support; the examples use Codex

The lab pins Kubernetes 1.34.0, OBI Helm chart 0.11.0 and OBI 0.10.0,
Tempo 2.10.7, Prometheus 3.12.0, Grafana 13.1.0, Grafana MCP 0.14.0, and
Go 1.23.12 on Alpine 3.22.

OBI requires Linux with eBPF and BTF support. The automation creates an
isolated Linux minikube node, verifies `/sys/kernel/btf/vmlinux`, and deploys
OBI as a privileged DaemonSet because this is a disposable lab. macOS and
Windows kernels cannot run OBI directly. Rootless containers, locked-down
clusters, and managed Kubernetes policies that reject privileged DaemonSets
may block some or all probes. Production deployments should replace
`privileged: true` with the minimum capabilities validated for their kernel and
features.

## 1. Start the zero-code lab

```shell
cd /Users/matthewleray/s2/mock-lab/obi
make up
```

In another terminal keep Grafana, Tempo, and Prometheus forwarded:

```shell
cd /Users/matthewleray/s2/mock-lab/obi
make forward
```

Grafana is at `http://127.0.0.1:3002` with disposable `admin` / `admin`
credentials. Tempo is at port 3202 and Prometheus at port 19090.

## 2. Record one slow boundary and its exact window

```shell
cd /Users/matthewleray/s2/mock-lab/obi
make capture RECORDING_DIR=proxymock/recording
```

The capture target starts proxymock around two Kubernetes port-forwards, sends
`GET /api/stats`, waits for the next scrape and trace export, and stops cleanly.
It writes nanosecond capture boundaries plus a conservative whole-second query
interval to:

```text
/Users/matthewleray/s2/mock-lab/obi/proxymock/recording/window.json
```

Grafana MCP 0.14.0 rejects fractional RFC3339 values. The script therefore
floors `query_start` and ceilings `query_end` itself; the agent passes those
fields unchanged. Nobody records, copies, rounds, substitutes, or confirms a
timestamp by hand. OBI's `ebpf.wakeup_len` is pinned to `1`, because the default
500-event threshold can delay a lone lab request for about a minute.

## 3. Connect Grafana and proxymock MCP

```shell
cd /Users/matthewleray/s2/mock-lab/obi
codex mcp add proxymock -- proxymock mcp run \
  --work-dir /Users/matthewleray/s2/mock-lab/obi
codex mcp add grafana -- docker run --rm -i \
  --add-host host.docker.internal:host-gateway \
  -e GRAFANA_URL=http://host.docker.internal:3002 \
  -e GRAFANA_USERNAME=admin \
  -e GRAFANA_PASSWORD=admin \
  grafana/mcp-grafana:0.14.0 -t stdio --disable-write \
  --enabled-tools datasource,prometheus,navigation
codex mcp list
```

`mcp.example.json` contains the equivalent configuration. Give the agent
`AGENT_TASK.md`. It names the actual Grafana MCP Prometheus tools and the Tempo
tools proxied through the provisioned datasource.

## 4. Replay behavior independently of telemetry

```shell
cd /Users/matthewleray/s2/mock-lab/obi
make functional-replay \
  RECORDING_DIR=proxymock/recording \
  RESULTS_DIR=proxymock/results/baseline
make load-replay \
  RECORDING_DIR=proxymock/recording \
  RESULTS_DIR=proxymock/results/baseline
make verify RESULTS_DIR=proxymock/results/baseline
```

Functional mode requires zero failed requests and a 100% stable response
match. Load mode runs only after that gate and sends 50 iterations from each of
two virtual users. A fixed iteration count prevents end-of-duration in-flight
requests from being counted as harness timeouts. Each successful replay
publishes its own `window.json`; a failed replay preserves
`failed-summary.json` for diagnosis but publishes no successful summary or
window.

The checked reference values live in `evidence/reference.json`. They are an
example from one machine, not a golden performance threshold.

## Measurement boundaries

- OBI provides HTTP transaction spans and RED metrics, not arbitrary internal
  function spans or business attributes. Add source instrumentation only when
  the boundary evidence cannot answer the next question.
- This lab uses unencrypted HTTP/1.1 between Go services. TLS, HTTP/2, gRPC,
  proxies, kernel lockdown, and CNI behavior can change context propagation.
- A local 120 ms fixture delay is deterministic evidence, not a production
  latency model. Replay measurements are directional and machine-specific.
- proxymock validates payload behavior and supplies aggregate latency and
  throughput. One trace is not a percentile, and telemetry presence is not a
  correctness assertion.
- Prometheus counters are cumulative. For a range, use the first and last
  samples for a delta when both exist. A series first created by the request
  begins at one, so that single value is the interval count; an empty 5xx
  selector means no error series was created in the interval.

## Primary references

- [proxymock MCP quickstart](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-mcp/)
- [OBI overview and requirements](https://opentelemetry.io/docs/zero-code/obi/)
- [Deploy OBI with Helm](https://opentelemetry.io/docs/zero-code/obi/setup/kubernetes-helm/)
- [OBI exported metrics](https://opentelemetry.io/docs/zero-code/obi/metrics/)
- [OBI distributed tracing limits](https://opentelemetry.io/docs/zero-code/obi/distributed-traces/)
- [OBI performance tuning](https://opentelemetry.io/docs/zero-code/obi/configure/tune-performance/)
- [Grafana MCP tools](https://grafana.com/docs/grafana/latest/developer-resources/mcp/reference/mcp-tools-table/)
- [Tempo MCP server](https://grafana.com/docs/tempo/latest/api_docs/mcp-server/)

When finished, stop `make forward` with Ctrl-C and delete only this lab's
isolated cluster:

```shell
make down
```
