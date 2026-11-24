# Discover sensitive fields in support notes

This lab compares value-pattern and JSON key-name discovery with model-assisted discovery on four synthetic `POST /tickets` RRPairs. It uses a local Ollama model and a committed recording. There is no support server to start.

| Field | Example | What to check |
| --- | --- | --- |
| Request `note` | Call Ada Rivera about the refund on Tuesday. | The free-text check can propose a whole-field redaction |
| Request `priority` | normal | The proposed rule preserves it |
| Response `summary` | Refund review is in progress with the billing queue. | Ordinary prose stays out of the findings |

## Prerequisites

Install [proxymock](https://docs.speedscale.com/proxymock/getting-started/installation/), [Ollama](https://ollama.com/download), and jq. In `proxymock recommendations list --help`, look for `--dlp-model-provider` and `--dlp-model-exposure`. Start `ollama serve` in a separate terminal if the app or service is not already running. Run the remaining commands from `labs/dlp-field-discovery`.

## Compare discovery with the model off and on

```bash
env -u SPEEDSCALE_DLP_MODEL_PROVIDER proxymock recommendations list \
  --in ./proxymock --type transform -o json \
  | jq '{analyzed, findings: [.items[] | {title, description}]}'

ollama pull qwen3:14b

SPEEDSCALE_DLP_MODEL_REASONING_EFFORT=none proxymock recommendations list \
  --in ./proxymock --type transform -o json \
  --dlp-model-provider openai-compatible \
  --dlp-model-base-url http://127.0.0.1:11434/v1 \
  --dlp-model qwen3:14b \
  --dlp-model-exposure samples \
  | jq '{analyzed, findings: [.items[] | {title, description}]}'
```

Both runs analyze four RRPairs. The baseline transform list is empty. With the local model, look for `FREE_TEXT_PII` on the request body’s `note` field. The response `summary` has ordinary prose and should stay out of the findings. The sample-mode run sends the synthetic field values to the loopback model endpoint. Model answers can vary. The workspace caches verdicts in `proxymock/.proxymock/` so the same recording can reuse them.

## Preview the rule

```bash
proxymock dlp test --dlp-config ./note-redaction.json \
  --in ./proxymock/recording

proxymock dlp test --dlp-config ./note-redaction.json \
  --show-redacted ./proxymock/recording/support.example/2026-11-24_12-00-01.000001Z.md
```

The summary reports four RRPairs and four fields that would be redacted. The rule masks `note` in all four requests and preserves `priority` and the response. The detailed preview lets you compare the original note with its `REDACTED-…` replacement. The recording contains fictional names and stays intact during the preview. The rule is intentionally scoped by field path for this small recording. [DLP discovery guide](https://docs.speedscale.com/guides/dlp/discovering-pii/)
