# Loki + proxymock rare retry path lab

This lab demonstrates a failure that happy-path testing never reaches. The
checkout API answers `GET /api/quote` by looking up a price. Seven of the
eight SKUs in the recording settle immediately. The eighth, `SSC-7300`, is
inside a repricing window, so the dependency answers `200 OK` with
`state=REPRICING`, no live price, and the last price it settled on. The
checkout client treats that answer as a transient failure: it retries three
more times with exponential backoff, gives up, logs an error, and then uses
the last settled price the dependency published on the very first response.

The response is correct either way, so no status code, no assertion, and no
response diff ever objects. The only evidence is in the logs — three warnings
and one error per occurrence — and in the tail of the latency distribution.

The lab is intentionally checked in with the retry loop. An agent should find
the pattern in Loki, correlate it to the recorded dependency response that
triggers it, make the smallest fix, and prove the response contract did not
change.

## Prerequisites

- Docker with Compose
- Go 1.23 or newer, `curl`, and `jq`
- proxymock 2.5.842 or newer, installed, initialized, and on `PATH`
- An MCP client with STDIO support; the examples use Codex

Run every command below from this `loki` directory of your `mock-lab` clone.

The lab pins Loki 3.5.7, Grafana Alloy v1.12.0, Grafana 13.1.0, and Grafana
MCP 0.14.0. Grafana binds to `127.0.0.1:3004` and Loki to `127.0.0.1:3100`
because the other reference labs in this repository use the neighboring ports.

The app writes structured JSON logs to `scratch/logs/checkout.log`; Alloy
tails that file and pushes every line to Loki under the stream label
`service="checkout"`. Nothing parses the log text — the fields the queries use
come from `| json`.

## 1. Start Loki, Alloy, and Grafana

```shell
make test
make up
```

Grafana is at `http://127.0.0.1:3004` with disposable `admin` / `admin`
credentials. Loki is at `http://127.0.0.1:3100`.

## 2. Record one ordinary shopping session

```shell
make capture RECORDING_DIR=proxymock/recording
```

The capture target starts the pricing fixture and the checkout API under
`proxymock record`, sends eight quotes through the inbound reverse proxy, and
stops cleanly. The recording holds 8 inbound quotes and 11 outbound price
lookups: seven SKUs needed one lookup each, and `SSC-7300` needed four because
the client retried it. Nothing about the capture is special — the rare
response was simply in the traffic on the day it was recorded.

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

Functional mode sends the eight recorded quotes once and requires zero failed
requests and a 100% stable response match. Load mode runs only after that gate
and sends 25 iterations from each of four virtual users, 800 requests, of
which exactly 100 take the rare path.

Each successful replay pauses for log ingestion, then records nanosecond UTC
boundaries and publishes a conservative whole-second query interval to its
`window.json`:

```text
proxymock/results/baseline/load/window.json
```

The `mkwindow` helper floors `query_start`, ceilings `query_end` past Alloy's
push interval, and precomputes `window_seconds`, so every Grafana MCP call
receives whole-second RFC3339 values and a ready-made LogQL range; the agent
passes those fields unchanged. Nobody records, copies, rounds, substitutes, or
confirms a timestamp by hand.

## 4. Connect Grafana and proxymock MCP

```shell
codex mcp add proxymock -- proxymock mcp run \
  --work-dir "$PWD"
codex mcp add grafana -- docker run --rm -i \
  --add-host host.docker.internal:host-gateway \
  -e GRAFANA_URL=http://host.docker.internal:3004 \
  -e GRAFANA_USERNAME=admin \
  -e GRAFANA_PASSWORD=admin \
  grafana/mcp-grafana:0.14.0 -t stdio --disable-write \
  --enabled-tools datasource,loki,navigation
codex mcp list
```

`mcp.example.json` contains the equivalent configuration. Give the agent
`AGENT_TASK.md`. It names the actual Grafana MCP Loki tools and the queries
that turn a log flood into a named state transition, a triggering SKU, and a
latency cost.

## 5. Make and test the smallest fix

The intended change is in `internal/checkout/checkout.go`: a repricing answer
already republishes the price the dependency settled on, and it stays
authoritative until the window closes, so the client should honor it on the
first response instead of retrying. The state transition still gets one log
line — the fix removes the retries, not the signal — and validation, the
error path for an unusable price, and every response field stay as they are.

After the agent edits the code, stop the baseline `make mock`, start it again
so it rebuilds the candidate, and repeat both evidence paths:

```shell
make functional-replay RESULTS_DIR=proxymock/results/candidate
make load-replay RESULTS_DIR=proxymock/results/candidate
make verify RESULTS_DIR=proxymock/results/candidate
```

Then call proxymock MCP `response_diff` exactly as `AGENT_TASK.md` shows and
repeat the LogQL queries over the candidate's own `window.json`.

## Validated reference evidence

The complete workflow was run locally on Apple arm64. Both query intervals
came directly from their `window.json` files and were passed unchanged to
Grafana MCP 0.14.0. [`evidence/reference.json`](evidence/reference.json)
retains the exact windows, log counts, and comparison results in one
machine-readable record. These values are an example from one machine, not a
golden performance threshold.

| Evidence (800-request load replay) | Baseline | Candidate |
| --- | ---: | ---: |
| Pricing calls per repricing quote | 4 | 1 |
| WARN lines | 300 | 100 |
| ERROR lines | 100 | 0 |
| `pricing_retry` events | 300 | 0 |
| `pricing_retry_exhausted` events | 100 | 0 |
| Quotes served from a live price | 700 | 700 |
| Quotes served from the last settled price | 100 | 100 |
| p95 served duration, live price | 2 ms | 1 ms |
| p95 served duration, last settled price | 432 ms | 1 ms |
| Replay p95 latency | 431 ms | 1 ms |
| Failed requests | 0 | 0 |
| Stable-field response differences | comparison source | 0 (none) |

The split of quotes by price source is identical, which is the point: the
service always made the same decision, and it took four dependency calls and
420 ms of backoff to reach it.

## Measurement boundaries

- Alloy assigns Loki timestamps as it reads the file, so a line's position in
  the stream can trail the `time` field inside the JSON by a fraction of a
  second. The replay targets pause before closing the window for that reason.
- `count_over_time` over a fixed range is an exact count of matching lines in
  that range. The exact replay request total still comes from proxymock's
  `summary.json`, because a log line is only evidence of what the app chose to
  log.
- `unwrap duration_ms` reads the app's own measurement of its handler. It is
  not the client-observed latency, which is what the replay summary reports.
- Load mode replays a mocked dependency that answers in about a millisecond,
  so the throughput difference between the runs exaggerates what a production
  fix would deliver. The direction is real; the multiple is a lab artifact.
- 12.5% is a deliberately generous rate for a rare path. A one-in-ten-thousand
  payload behaves the same way but needs a much longer replay to produce
  comparable counts.
- Retrying an unsettled dependency answer is not always wrong. It is wrong
  here because the dependency publishes an authoritative price in the same
  response; a dependency that publishes nothing usable still needs the retry
  and the error path this lab keeps.

## Primary references

- [proxymock MCP quickstart](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-mcp/)
- [LogQL query language](https://grafana.com/docs/loki/latest/query/)
- [LogQL metric queries](https://grafana.com/docs/loki/latest/query/metric_queries/)
- [Grafana Alloy loki.source.file](https://grafana.com/docs/alloy/latest/reference/components/loki/loki.source.file/)
- [Go log/slog](https://pkg.go.dev/log/slog)
- [Grafana MCP tools](https://grafana.com/docs/grafana/latest/developer-resources/mcp/reference/mcp-tools-table/)

When finished, stop `make mock` with Ctrl-C and remove only this lab's Compose
stack and its volumes:

```shell
make down
```
