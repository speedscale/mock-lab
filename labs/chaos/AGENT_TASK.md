# Coverage, chaos and response behavior

Work from `labs/chaos`. Use Node and native proxymock features. Read the README and establish the evidence before editing `app.js`.

1. Run `make coverage`. Report the actual Node coverage numbers and the dependency outcomes tested. Identify the missing 503-with-valid-JSON and latency cases. Do not equate exercised lines with correct behavior.
2. Start `make mock`, run `make baseline`, and save the six healthy responses. Stop it, start `make mock-chaos`, then run `make baseline` and `make chaos-evidence`. Show the dependency's injected 503 and chaos marker beside the app's false healthy response.
3. Explain the missing status check in `fetchStock`. Add the smallest fix and an HTTP regression test. The accepted behavior is 503 with an empty cache, or cached stock with `degraded:true` and `source:"cache"`. Preserve the response shape and recording.
4. Stop and restart `make mock-slow`. Run `make slow-evidence` before changing the timeout. Review the candidate 750 ms response requirement, bound the dependency timeout below it and add tests for cached and empty-cache timeout responses. Restart after changing code and measure actual elapsed time.
5. Use the seeded flaky mode to compare each observed dependency fault with the app response. Run enough requests to exercise healthy, empty-cache failure and cached degraded results. Never count an inactive fault or unrelated error as success.
6. Restart the healthy mock. Verify unchanged healthy responses, then run the bounded replay and native score from the README. Report correctness, p95, failed requests and mock matching. Retain native output; do not report local RPS as production capacity.

Save reviewed expectations and native commands so reruns need no model. Keep generated, exercised and passed coverage separate. No new test runner, npm dependencies or proxymock CLI commands are needed.
