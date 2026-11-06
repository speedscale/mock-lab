# Refactor a typed API client without losing its JSON contract

The Go app returns 24 projects grouped by maturity. This exercise replaces its untyped project maps with a typed model and an aggregation helper. One draft maps the internal `Lifecycle` field to the wrong JSON property. It compiles and its helper test passes, but `/api/stats` returns an empty maturity breakdown with HTTP 200.

The recording already contains the expected breakdown: 16 Graduated, 5 Incubating and 3 Sandbox projects. proxymock catches the changed response. Correcting the JSON tag to `maturity` preserves the refactor and restores the recorded behavior.

The wrong tag is deliberately staged for the demo. This is an assisted-refactor exercise with a known regression, not a claim that a particular coding tool independently produced it.

## Run in Docker

From the repository root:

```bash
./labs/ai-refactor/run.sh /absolute/path/to/dev-config.yaml
```

Requires Docker, Git, curl, Python 3 and a working proxymock dev configuration. The runner uses the dev endpoint explicitly. The configuration is mounted read-only at runtime and is excluded from the image and build context. Noninteractive replay requires the appropriate Speedscale plan.

The runner downloads proxymock v2.5.1250 and verifies its SHA-256 against the version used by the existing CI tutorial. The Linux amd64 Go 1.27.3 image is pinned by digest. Docker may emulate amd64 on an ARM host. Image builds have networking disabled. Runtime networking allows CLI initialization against Speedscale dev; this is not an offline demo.

Each invocation creates a fresh container with no published ports, Docker socket or app-source mount. All capabilities are dropped and memory, CPU and process counts are bounded. The application's downstream responses come from the committed recording with passthrough disabled.

## What runs

| Application | Helper test | HTTP result | Native replay gate |
| --- | --- | --- | --- |
| Original at `382e4a79e1eb1ae65960f6bec0be8b4b9a546f65` | No helper test | 200, original maturity counts | Pass |
| Refactor with `json:"lifecycle"` | Pass | 200, total 24, empty counts | One new `/api/stats` response mismatch |
| Refactor with `json:"maturity"` | Pass | 200, original maturity counts | Pass |

The helper test constructs typed values, so it does not exercise the downstream JSON mapping. The replay supplies the recorded downstream payload and exercises that boundary through the running app. A JSON integration test could also catch this bug.

All runs use the same eight inbound requests from the committed synthetic demo recording, recorded downstream responses and existing token/order-ID blueprint. The first run saves a clean native baseline. Both refactors use `--baseline` and `--fail-on-new-mismatch`; the runner checks the native verdict as well as the process exit code. It requires exit 3 for the broken draft and exit 0 for the original and corrected draft.

`results/<timestamp>/summary.json` contains the results. Adjacent files preserve native replay verdicts, observed traffic, application responses, helper-test logs and recording checksums. Source fixture files must remain byte-identical. Output stays local and is ignored by Git. Pass a second argument to select an output directory.

Repeat the command for an independent fresh-container run. No model is needed to reproduce the saved exercise. Eight requests cover this recorded journey; they do not establish the behavior of unrecorded inputs.
