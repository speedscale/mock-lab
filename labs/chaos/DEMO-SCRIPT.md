# Demo: coverage passes while the service lies

**Runtime:** 6 to 8 minutes

**Audience:** Developers and platform teams using coding agents

**Point:** Code coverage tells you which lines ran. It cannot tell you whether an API honored its contract, met its latency objective, or handled a failed dependency correctly.

## Before recording

Use the `mock-lab` repository on the `demo/coverage-behavioral-nfr` branch. Start in `labs/chaos` and verify the committed recording has six inbound stock requests and six healthy inventory responses. Use a terminal with proxymock initialized. Keep the recording unchanged throughout the demo.

## 0:00 | Show the coverage result

Run:

```shell
make coverage
```

**Show:** The package reports 77.6% statement coverage. `fetchStock` reports 100.0%.

**Say:**

"The inventory client is fully covered by these tests. They exercise a successful JSON response, malformed JSON, and a connection error. They do not test a 503 response with a valid JSON body. The code can run every line and still accept a failed dependency as healthy."

Open `cmd/app/main_test.go` long enough to show which outcomes it asserts. The omission is about expected behavior, not a broken coverage tool.

## 0:45 | Establish the healthy baseline

In terminal one, start the mocks and app:

```shell
make mock
```

In terminal two:

```shell
make baseline
```

**Show:** The app returns inventory data and marks it `degraded:false` with `source:"inventory"`.

## 1:30 | Break only the dependency

Stop the first mock and start:

```shell
make mock-chaos
```

Then run:

```shell
make baseline
make chaos-evidence
```

**Show:** Inventory returned 503 with an `X-Speedscale-Chaos` marker. The storefront still returns `degraded:false` and `source:"inventory"` because the recorded body is valid JSON.

**Say:**

"The body looks fine. The status says the dependency failed. The app only checked whether the body parsed, so it reports fresh data and skips the fallback. A status or body-only comparison would miss the contract failure."

## 2:45 | Let the agent fix behavior

Give the coding agent this task:

```text
Fix the inventory client so a non-2xx response is treated as a dependency failure before its body is decoded. Add a regression test for HTTP 503 with a valid JSON body. Keep the response schema and recording unchanged. The service must serve cached stock with degraded=true when available, and return HTTP 503 when no cached stock exists. Run the tests and explain the replay evidence.
```

Inspect the code change and the new test. Then stop chaos mode and run the healthy mock again to confirm the ordinary response is unchanged. Restart with `make mock-flaky` and call `make baseline` several times. Show healthy inventory results, cached degraded results, and the error returned before any cached result exists.

## 4:30 | Test the latency requirement

Stop the flaky mock and start `make mock-slow`. Run:

```shell
make slow-evidence
```

**Show:** The dependency response is delayed by 2 seconds. The app currently allows up to 5 seconds, while this example service has a 750 ms response objective.

Ask the agent to set a bounded inventory timeout and add a test for that requirement. Restart `make mock-slow` and run `make slow-evidence` again. The request should return before 750 ms with an honest error when no fallback is available.

## 5:30 | Enforce a latency gate under replay load

Restart a healthy mock with `make mock`. In another terminal, run:

```shell
proxymock replay --in proxymock/recording --test-against http://127.0.0.1:8080 \
  --vus 4 --for 10s --fail-if 'latency.p95>750' --fail-if 'requests.failed!=0'
```

**Show:** The replay uses recorded inbound requests while the mock serves downstream dependencies. Review the p95 result and request failures. The thresholds are demo service objectives, not universal recommendations. Keep the CPU attribution visible: a local mock and generator can limit the run before the app does, so treat the p95 gate as a same-runner regression check and do not quote local RPS as app capacity.

## 6:30 | Close

**Say:**

"Keep line coverage. It tells you what ran. Then test the outcomes your users and other services depend on: response contracts, time limits, and behavior when a dependency fails. Traffic replay gives the agent and the reviewer repeatable evidence for those checks."

## Recording notes

- Keep the original recording intact. The chaos rule changes responses at mock time, so the observed failure remains attributable and repeatable.
- Show the injected-failure marker beside the dependency response so viewers can distinguish test setup from an application-produced error.
- If the replay report or CLI options differ on the recording machine, update this script from the actual run before filming.
- Do not imply that traffic capture supplies expected behavior for requirements it has never observed. The test assertions define that contract.
