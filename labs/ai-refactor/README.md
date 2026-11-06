# Let your agent catch a broken refactor

The app still returns HTTP 200 and a total of 24 projects. Its unit test passes. But a typed-client refactor has emptied the maturity breakdown:

```text
NEW MISMATCH: GET /api/stats status 200, body by_maturity.Graduated removed (was 16) (+2 more)
```

That is proxymock's output from replaying the existing mock-lab recording. The other missing counts are Incubating (5) and Sandbox (3). Your agent can use the failed replay to find the JSON mapping error, fix the code and rerun the same requests.

This lab has its own copy of the small [Go app](../../languages/go/README.md). It reuses that app's recording and token/order-ID blueprint. The supplied `draft.patch` makes the broken refactor repeatable; the agent completes and verifies it. We do not claim that a coding tool independently generated this particular mistake.

## Set up your workstation

Install [Go 1.23 or newer](https://go.dev/doc/install) and [proxymock](https://docs.speedscale.com/proxymock/getting-started/installation/). Clone mock-lab and enter this lab:

```bash
git clone https://github.com/speedscale/mock-lab.git
cd mock-lab/labs/ai-refactor
```

Activate proxymock with `proxymock init` and complete browser sign-in. The normal [free signup](https://app.speedscale.com/signup) is the same one used by the repository's quickstart; [free-use eligibility](https://speedscale.com/terms-service/) applies. Reuse an existing activated configuration if you have one.

Connect your agent with `proxymock mcp install --yes`, then install the [Speedscale skills](https://github.com/speedscale/skills) with `npx skills add speedscale/skills` if they are not already available. Restart the agent in this lab directory so it loads the MCP server and skills. This is a local workstation exercise; it needs Go and proxymock, with no Docker setup or cloud snapshot.

## Ask your agent to finish the refactor

Give it this prompt:

```text
Use quality-loop and proxymock-regression-test to finish this lab's
supplied typed-client refactor. Start the app with recorded dependencies
mocked and save a passing baseline from the eight requests in
../../languages/go/proxymock/recording. Keep the existing token/order-ID
blueprint active.

Apply draft.patch with git apply. Run the helper test, restart the app,
and use the proxymock MCP replay_traffic tool with that baseline and
fail-on-new-mismatch before repairing the draft. Read the native response
diff with response_diff when replay fails. Fix application code, preserve the typed refactor,
and replay again against the same baseline. Keep the recording, blueprint
and acceptance settings unchanged. Show the failed diff and final verdict.
```

The helper test constructs typed project values. It misses the JSON mapping error because it never decodes a downstream response. The replay exercises that boundary through the running application.

## The visible commands

Run these from this lab directory. In terminal 1, start the original app under recorded mocks:

```bash
proxymock mock --in ../../languages/go/proxymock/recording --no-passthrough -- go run .
```

In terminal 2, save the baseline and apply the draft:

```bash
proxymock replay --in ../../languages/go/proxymock/recording --test-against localhost:8080 --out proxymock/results/baseline
git apply draft.patch
go test ./...
```

Stop terminal 1 with Ctrl-C and rerun its `proxymock mock` command to build the changed app. Then replay in terminal 2:

```bash
proxymock replay --in ../../languages/go/proxymock/recording --test-against localhost:8080 --baseline proxymock/results/baseline --fail-on-new-mismatch --out proxymock/results/draft
```

The command exits 3 and prints the mismatch above. The agent's `response_diff` MCP call makes each missing field visible:

```text
Response diff: proxymock/results/baseline (8 responses) → proxymock/results/draft (8 responses)
Compared 8 paired response(s); 17 volatile field(s) filtered as noise.

Findings (4):
  ⚠ [value_changed] GET /api/stats · http.res.headers.Content-Length[0]: 70 → 29
  - [field_removed] GET /api/stats · http.res.bodyBase64.by_maturity.Graduated: 16
  - [field_removed] GET /api/stats · http.res.bodyBase64.by_maturity.Incubating: 5
  - [field_removed] GET /api/stats · http.res.bodyBase64.by_maturity.Sandbox: 3

By endpoint:
  GET /api/stats               4 finding(s) across 1 compared response(s)
```

After your agent fixes the mapping, restart terminal 1 again and repeat the gated replay with `--out proxymock/results/repaired`. Keep the original baseline. All eight recorded requests should pass, with the maturity counts restored. The [replay-verdict guide](https://docs.speedscale.com/proxymock/guides/replay-verdicts/) explains the native status/body checks and exit codes.

| Version | Helper test | HTTP /api/stats | Gated replay |
| --- | --- | --- | --- |
| Original | No helper test | 200, total 24, counts 16/5/3 | Baseline passes |
| Supplied draft | Pass | 200, total 24, empty counts | One new mismatch, exit 3 |
| Agent repair | Pass | 200, total 24, counts 16/5/3 | Eight requests pass, exit 0 |

The [verified agent repair](repair.patch) keeps the typed model, corrects its JSON mapping and adds a handler test that decodes a downstream response. You can inspect it after attempting the exercise.

The recording contains synthetic demo traffic. It covers this journey, including the authenticated order flow; keep tests for behavior outside that recording too.
