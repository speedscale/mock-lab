# Demo: high coverage, wrong behavior

Allow six to eight minutes. Use Node and initialized proxymock from `labs/chaos`. Keep the recording unchanged. Every mode change below requires stopping the prior mock; every app edit requires a restart.

1. Run `make coverage`. Show the actual Node report and `app.test.js`. On Node 24.19.0, app line coverage is 94.74%, including every line of `fetchStock`. Explain that the tests omit 503 with valid JSON and slow dependencies.
2. Start `make mock` and run `make baseline` in another terminal. Show healthy inventory data. The inventory server is stopped; dependency responses come from the recording.
3. Switch to `make mock-chaos`. Run `make baseline` and `make chaos-evidence`. Put the injected 503 and its marker beside `degraded:false` and `source:"inventory"`. The app decodes the body without checking dependency status.
4. Give the agent the behavior prompt from the README. Inspect the status check and its regression test. Restart the total-outage mock: an empty cache must produce an honest 503. Then use seeded flaky mode and repeated baseline calls to show healthy and cached degraded responses. Show the actual faulted calls; do not promise all states on the first pass.
5. Switch to `make mock-slow` and run `make slow-evidence`. The starter takes about two seconds, beyond the candidate 750 ms requirement. Ask the agent for a bounded timeout and tests. Restart after the edit; show an honest empty-cache 503 before the deadline and verify cached timeout behavior separately.
6. Restart a healthy mock and run the bounded replay and native score from the README. Show unchanged responses, passing latency and measured mock matching. Explain that line coverage, response behavior and latency answer different questions.

Check the actual CLI output before filming. The starter intentionally passes its incomplete tests while failing the behavior and latency requirements. Do not present it as a finished resilient service, or claim that the recording supplies expectations for outcomes it never captured. The reviewed requirements define those expectations.
