# LLM streaming metrics lab

This lab records streamed LLM chat traffic with proxymock and replays it to measure time to first token (TTFT), inter-token latency (ITL) and token rates, using the metric definitions from [NVIDIA AIPerf](https://github.com/ai-dynamo/aiperf/blob/main/docs/metrics-reference.md). It then slows the model server down and shows the replay failing on the regression.

The model server is a stand-in for an inference server such as vLLM or NVIDIA NIM. It streams a canned answer one token at a time, so the timing is set by environment variables instead of a GPU:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FIRST_TOKEN_MS` | `300` | Delay before the first output token |
| `TOKEN_GAP_MS` | `20` | Delay between output frames |
| `TOKENS` | `20` | Output tokens per answer |
| `TOKENS_PER_FRAME` | `1` | Output tokens sent in each frame |
| `PORT` | `8000` | Listen port |

It speaks the four streaming formats Speedscale measures:

| Format | Endpoint | Content type |
| --- | --- | --- |
| OpenAI-compatible chat completions | `POST /v1/chat/completions` | `text/event-stream` |
| Anthropic Messages | `POST /v1/messages` | `text/event-stream` |
| Ollama native chat | `POST /api/chat` | `application/x-ndjson` |
| Amazon Bedrock ConverseStream | `POST /model/{model}/converse-stream` | `application/vnd.amazon.eventstream` |

The chat client sends a mix of short questions and longer pasted tickets with a system prompt, the way an application in front of a model would.

The [LLM streaming metrics guide](https://docs.speedscale.com/guides/replay/llm-streaming-metrics/) is the reference for every metric and goal name used here.

## Prerequisites

- Go 1.23 or newer, `curl` and `nc`
- proxymock 2.5.1370 or newer, installed, initialized and on `PATH`

Run every command below from this `labs/llm-streaming` directory of your `mock-lab` clone.

## 1. Start the model server

```shell
make server
```

Leave it running. It listens on port 8000.

## 2. Record streamed traffic

In a second terminal:

```shell
make record
```

The script starts `proxymock record --app-port 8000`, sends eight streamed chat completions through proxymock's inbound port 4143 and stops the recorder. Each line the client prints is one request:

```text
openai    200  first byte    2.0 ms  done  703.5 ms   4559 bytes  "Where is order 48213?"
```

The first byte arrives at once because the server's first frame only names the role. The first token arrives about 300 ms later, and that is the moment TTFT measures.

`proxymock record` stores the arrival time of every frame of a streamed response. A recorded request's `httpStream` block lists them; the first frame with output is at about 301 ms, and each one after it about 21 ms later. That recorded timing is what a replay is compared against.

The lab includes a recording made this way in `proxymock/recording`, so you can skip this step. `make record FORMAT=anthropic`, `FORMAT=ollama` or `FORMAT=bedrock` records the other formats.

## 3. Replay and gate on the LLM metrics

```shell
make replay
```

This runs:

```shell
proxymock replay --in proxymock/recording --test-against http://localhost:8000 \
  --out proxymock/results/replay \
  --fail-if 'llm.ttft-p95 > 800' \
  --fail-if 'llm.itl-p95 > 40'
```

The replay passes and `proxymock` exits 0:

```text
2 EVALS PASSED
 ✔ passed eval "llm.ttft-p95 > 800.00" - observed llm.ttft-p95 was 301.67
 ✔ passed eval "llm.itl-p95 > 40.00" - observed llm.itl-p95 was 21.06
```

## 4. Catch a regression

Stop the server and start a slower one, as a heavier model, a smaller GPU or a gateway change might be:

```shell
make slow-server
```

`slow-server` waits 900 ms for the first token and 50 ms between tokens. Replay the same recording:

```shell
make replay
```

Both gates fail. `proxymock` exits 1, so `make` stops with an error:

```text
2 EVALS FAILED
 ✘ failed eval "llm.ttft-p95 > 800.00" - observed llm.ttft-p95 was 901.59
 ✘ failed eval "llm.itl-p95 > 40.00" - observed llm.itl-p95 was 51.08
```

When a gate fails, the output also lists every LLM metric, with the recorded value of each one beside the replayed set:

```text
llm.ttft-p95: 901.59
llm.itl-p95: 51.08
llmTtftP95Recorded: 301.29
llmItlP95Recorded: 21.07
```

The response verdict still says `pass`, because the slow server returned the same status, headers and body shape. Only the streaming metrics show the regression.

## 5. Put the gates in a test config

The lab includes `proxymock/testconfigs/llm-gates.json`. It was made with `proxymock test-config new llm-gates --from regression` and these rules added to its `rules` array:

```json
{ "metricName": "llmTtftP95", "type": "TOO_HIGH", "value": 800, "action": "ALERT" },
{ "metricName": "llmItlP95", "type": "TOO_HIGH", "value": 40, "action": "ALERT" },
{ "metricName": "llmIncompleteCount", "type": "TOO_HIGH", "value": 0, "action": "ALERT" }
```

The `regression` config checks the status code, the `Content-Type` header and the response schema, not the generated text. Run it against the slow server:

```shell
make replay-goals
```

```text
TEST CONFIG GOALS (llm-gates)
 PASS passAssertPct >= 100 - observed 100 (counts assertions, not requests: each replayed request carries one assertion per configured type, so this is not the match rate)
 FAIL llmTtftP95 <= 800 - observed 901.66 (same measure as --fail-if llm.ttft-p95)
 FAIL llmItlP95 <= 40 - observed 51.08 (same measure as --fail-if llm.itl-p95)
 PASS llmIncompleteCount <= 0 - observed 0 (same measure as --fail-if llm.incomplete)
 PASS failedVUsers <= 0 - observed 0 (applied to every report by the analyzer)
Goal verdict: FAIL
```

Against `make server` every goal passes and `proxymock` exits 0.

## 6. See why usage reports matter

ITL and the token rates divide by the output token count. Speedscale takes the count from the stream's usage report, and OpenAI-compatible servers send one only when the request sets `stream_options.include_usage`. Without it, each output frame counts as one token.

Start a server that sends four tokens per frame, then record without asking for usage and with it:

```shell
make server TOKENS_PER_FRAME=4
make record RECORDING_DIR=proxymock/recorded-no-usage USAGE=false
make record RECORDING_DIR=proxymock/recorded-usage
```

Replay each with `make replay RECORDING_DIR=...`. The run without usage reports `llm.token-count-approx-pct` of 100, 40 output tokens instead of 160, and an ITL p50 of about 21 ms. With usage, the same server measures 160 tokens and an ITL p50 of about 4.4 ms. Gate on `llm.token-count-approx-pct > 0` when token rates matter.

## 7. Load and other formats

```shell
make load
```

`make load` replays with four virtual users for 20 seconds in `--load-test` mode, which also reports LLM metrics. To compare concurrency levels, run one replay per `LOAD_VUS` value; the metrics cover the whole run.

Recordings of the Anthropic, Ollama and Bedrock formats replay the same way, each with a TTFT p95 of about 301.5 ms against `make server` and exact token counts from their usage fields.

## 8. Optional: the Speedscale report

A replay run in Speedscale cloud produces a report with an **LLM** tab that shows each metric beside its recorded value and highlights a change of 10% or more in the wrong direction. The **Stream** tab of any streamed request plots its frames on a time axis with TTFT and the last output marked. See [the guide](https://docs.speedscale.com/guides/replay/llm-streaming-metrics/#read-the-results).

## What this lab does not show

- A mocked LLM sends the recorded stream in one write, so this lab replays against the server rather than mocking it.
- The stand-in server's TTFT does not grow with prompt length, as a real server's does.
- Metrics cover the whole run, with no per-stage values or concurrency sweep.
