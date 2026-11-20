# LLM streaming metrics lab

This lab records streamed LLM chat traffic with proxymock and replays it to measure time to first token (TTFT), inter-token latency (ITL) and token rates, using the metric definitions from [NVIDIA AIPerf](https://github.com/ai-dynamo/aiperf/blob/main/docs/metrics-reference.md). It then slows the model server down and shows the replay failing on the regression.

The last part swaps in a model that answers as fast and gets two answers wrong, and shows a replay failing on the answers themselves.

The model server is a stand-in for an inference server such as vLLM or NVIDIA NIM. It streams a canned answer one token at a time, so the timing is set by environment variables instead of a GPU:

| Variable | Default | Meaning |
| --- | --- | --- |
| `FIRST_TOKEN_MS` | `300` | Delay before the first output token |
| `TOKEN_GAP_MS` | `20` | Delay between output frames |
| `TOKENS` | `20` | Output tokens per answer |
| `TOKENS_PER_FRAME` | `1` | Output tokens sent in each frame |
| `PORT` | `8000` | Listen port |
| `MODE` | `normal` | `regressed` gets one tool call and one written answer wrong, see [step 8](#8-gate-a-model-swap-on-answer-quality) |
| `MODEL_NAME` | unset | When set, a request that names another model gets a 404 |
| `API_KEY` | unset | When set, a request without this key gets a 401 |

It speaks the four streaming formats Speedscale measures:

| Format | Endpoint | Content type |
| --- | --- | --- |
| OpenAI-compatible chat completions | `POST /v1/chat/completions` | `text/event-stream` |
| Anthropic Messages | `POST /v1/messages` | `text/event-stream` |
| Ollama native chat | `POST /api/chat` | `application/x-ndjson` |
| Amazon Bedrock ConverseStream | `POST /model/{model}/converse-stream` | `application/vnd.amazon.eventstream` |

The chat client sends a mix of short questions and longer pasted tickets with a system prompt, the way an application in front of a model would.

The [LLM streaming metrics guide](https://docs.speedscale.com/guides/replay/llm-streaming-metrics/) is the reference for every metric and goal name used here. [Regression Test a Model Swap](https://docs.speedscale.com/proxymock/guides/llm-eval-gate/) is the reference for step 8.

## Prerequisites

- Go 1.23 or newer, `curl`, `nc` and `jq`
- proxymock 2.5.1370 or newer, installed, initialized and on `PATH`. Step 8 needs 2.5.1445 or newer.

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

This empties `proxymock/results/replay` and runs:

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

A passing replay prints only the metrics it gates on, so `make llm-metrics` replays a recording and prints every LLM metric of the run:

```shell
make llm-metrics RECORDING_DIR=proxymock/recorded-no-usage
make llm-metrics RECORDING_DIR=proxymock/recorded-usage
```

The run without usage reports `llm.token-count-approx-pct` of 100, 40 output tokens instead of 160, and an ITL p50 of about 21 ms. With usage, the same server measures 160 tokens and an ITL p50 of about 4.4 ms. Gate on `llm.token-count-approx-pct > 0` when token rates matter.

## 7. Load and other formats

```shell
make load
```

`make load` replays with four virtual users for 20 seconds in `--load-test` mode, which also reports LLM metrics. To compare concurrency levels, run one replay per `LOAD_VUS` value; the metrics cover the whole run.

Recordings of the Anthropic, Ollama and Bedrock formats replay the same way, each with a TTFT p95 of about 301.5 ms against `make server` and exact token counts from their usage fields.

## 8. Gate a model swap on answer quality

A new model can be as fast as the old one and still answer worse. The steps above would pass it. This step replays recorded prompts at two models and fails the one whose answers changed.

It uses a second recording, `proxymock/eval-recording`, of an assistant that can look orders up. Every request in it carries tool definitions. The model answered three of the eight with a `get_order` tool call and the rest in writing. `make eval-record` makes it again.

```shell
make eval-gate
```

The target starts two model servers on ports 8010 and 8011, so it needs no other terminal. The first answers as the recording did. The second runs with `MODE=regressed`, serves the model name `checkpoint-b` and accepts only its own API key, as a new checkpoint on its own server would.

It replays the recording at each one with two conditions on the answers:

```shell
proxymock replay --in proxymock/eval-recording --test-against http://localhost:8010 \
  --out proxymock/results/eval-baseline \
  --fail-if 'llm.tool-call-match-pct < 100' \
  --fail-if 'llm.failure-pct > 0'
```

Against the first model both conditions hold and `proxymock` exits 0:

```text
LLM quality: 8 scored · tool calls 3/3 matched (100.0%) · divergence 0.0% · failures 0.0%
  warning: only 8 scored pair(s); each one moves these rates by 12.5 points
```

The warning is fair. Eight prompts are enough for a lab and too few to gate a real model on.

The replay at the second model adds two flags, because that server would reject the recorded model name and key:

```shell
--llm-model checkpoint-b --llm-api-key-env LAB_CANDIDATE_KEY
```

`--llm-model` replaces the model name in each request. `--llm-api-key-env` names the environment variable that holds the key to send in place of the recorded one. This replay fails and `proxymock` exits 1:

```text
LLM FAIL: POST /v1/chat/completions get_order: order_id 77120 -> 77210
LLM quality: 8 scored · tool calls 2/3 matched (66.7%) · divergence 25.0% · failures 12.5%

2 EVALS FAILED
 ✘ failed eval "llm.tool-call-match-pct < 100.00" - observed llm.tool-call-match-pct was 66.67
 ✘ failed eval "llm.failure-pct > 0.00" - observed llm.failure-pct was 12.50
```

The regressed model swapped two digits of an order number. Its response has the same status, headers and shape as the recorded one, so the response verdict still says `pass`. Only the tool-call comparison shows that the assistant would have looked up the wrong order.

Last, the target scores the second run against the first:

```shell
proxymock replay score proxymock/results/eval-candidate \
  --baseline proxymock/results/eval-baseline \
  --html proxymock/results/eval-comparison.html
```

```text
LLM quality: 8 scored · tool calls 2/3 matched (66.7%) [-33.3 pts] · divergence 25.0% [+25.0 pts] · failures 12.5% [+12.5 pts]
             vs baseline: 8 request(s) compared, 2 got worse, 0 got better
             match -> fail  get_order: order_id 77120 -> 77210  ("Can I change the shipping address on order 77120 before it leaves the warehouse?")
             match -> divergent  answer text similarity 0.80  ("What is your return policy for opened electronics?")
             llm.ttft-p95 301.75 -> 361.68 (+19.9%)
```

Two prompts got worse. The wrong order number is a failure. The return policy answer was reworded and says the same thing, so it is `divergent`: different enough to look at, not different enough to fail. Neither condition above counts it. A condition on `llm.divergence-pct` would.

The comparison also shows that the second model is slower to its first token. Open `proxymock/results/eval-comparison.html` for the same comparison as a page.

To run one replay yourself, start a server with `make server` or `make regressed-server` and run `make eval-replay`.

`make eval-record FORMAT=anthropic EVAL_RECORDING_DIR=proxymock/eval-anthropic` records the same assistant in another format, and `make eval-gate EVAL_RECORDING_DIR=proxymock/eval-anthropic` gates it. `FORMAT=ollama` and `FORMAT=bedrock` work the same way. These three formats need proxymock 2.5.1459 or newer.

## 9. Optional: the Speedscale report

A replay run in Speedscale cloud produces a report with an **LLM** tab that shows each metric beside its recorded value and highlights a change of 10% or more in the wrong direction. The **Stream** tab of any streamed request plots its frames on a time axis with TTFT and the last output marked. See [the guide](https://docs.speedscale.com/guides/replay/llm-streaming-metrics/#read-the-results).

## What this lab does not show

- A mocked LLM sends the recorded stream in one write, so this lab replays against the server rather than mocking it.
- The stand-in server's TTFT does not grow with prompt length, as a real server's does.
- Metrics cover the whole run, with no per-stage values or concurrency sweep.
- The stand-in server gives the same answer to the same prompt every time. A real model does not, so measure how much its answers vary between two replays before you choose conditions.
- Step 8 uses no judge model. A judge can rule on answers that land in the divergent band.
