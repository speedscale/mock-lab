# Chaos, coverage and response behavior

This independent Node lab shows why high code coverage does not prove that an app handles a failed dependency or meets a latency requirement. The storefront reads inventory through proxymock and has a cache fallback. Its starter client accepts a valid JSON body even when inventory returns 503. The starter tests pass because they never assert that case.

You need Node 24+ (or 22.21+), initialized proxymock v2.5.1133 or newer, make and curl. No npm packages, Go, Docker, database or cluster are needed. From the repository root, run `cd labs/chaos`. Run all commands below from this directory. The app uses port 8080, inventory 8090 and proxymock 4140/4141/4143; run one mock at a time.

## Show what coverage misses

```sh
make coverage
```

Node's built-in test runner reports line, branch and function coverage for `app.js`. On Node 24.19.0 the starter has 94.74% line coverage, and the lines in `fetchStock` all run. Read `app.test.js`: successful JSON, invalid JSON, connection errors and cache fallback are exercised. A 503 with valid JSON and a slow dependency are absent. The CI job checks this intentionally incomplete starter suite, not full resilience.

## Replay a healthy baseline

The committed recording has six inbound stock reads and six healthy outbound inventory calls. It works offline. Inventory does not need to run:

```sh
make mock
```

In another terminal:

```sh
make baseline
```

Expect six healthy results with `degraded:false` and `source:"inventory"`. Results stay under ignored `proxymock/results/healthy`. The Makefile enables Node's built-in proxy support and clears loopback proxy exclusions so local inventory calls reach the mocks. Only local HTTP is used, so no extra TLS setup is needed.

## Make inventory fail

Stop the healthy mock with Ctrl-C and start:

```sh
make mock-chaos
```

In the second terminal:

```sh
make baseline
make chaos-evidence
```

The dependency returns 503 with `X-Speedscale-Chaos: effect=status code;status=503;rule=chaos-1`. The app still reports healthy inventory data. The recorded body survives the status injection, so JSON decoding succeeds. The app's status and body match its healthy baseline while its claim about the dependency is wrong. This is a behavior requirement that response shape alone cannot establish.

Ask the agent:

> Check the inventory response status before accepting its body. Add an HTTP regression test for 503 with valid JSON. Require an honest 503 when the cache is empty and a 200 with degraded=true and source=cache when stock was previously cached. Preserve healthy responses and the recording. Run the tests and show the dependency's chaos marker beside the app's actual response.

The committed app deliberately leaves this fix for the exercise. Stop the faulted mock before switching modes. After the fix, total outage should produce honest errors with an empty cache. To exercise both healthy and cached results:

```sh
make mock-flaky
```

Run `make baseline` several times from another terminal. Check responses against the actual faulted dependency calls in the retained output. `percent=50,seed=lab` is repeatable per request signature and occurrence; differing request counts can change the sequence. A seeded run is not a guarantee that every state appears in one six-request pass.

## Test a latency requirement

Stop the current mock and start:

```sh
make mock-slow
```

Then:

```sh
make slow-evidence
```

Inventory is delayed by two seconds; the starter allows five seconds. This exercise's candidate requirement is an app response within 750 ms, with cached data or an honest 503. Review that requirement before accepting it as a baseline. Ask the agent to bound the inventory timeout below the app budget, add a slow-dependency test, and prove both empty-cache and cached behavior. The delay has no start window, so app startup time cannot consume the fault.

Stop and restart `make mock-slow` after editing the app. An empty-cache timeout should now return 503 before 750 ms. Verify the dependency's latency chaos marker in the retained mock run; a missing mock or unrelated failure does not prove the timeout requirement.

## Keep a bounded replay gate

Stop the faulted mock and restart `make mock`. In the second terminal:

```sh
proxymock replay --in proxymock/recording --test-against http://127.0.0.1:8080 \
  --rewrite-host --test-config regression --vus 4 --for 10s --fail-if 'latency.p95>750' \
  --fail-if 'requests.failed>0' --out proxymock/results/healthy-load
proxymock replay score proxymock/results/healthy-load --mock-run proxymock/results/healthy -o json
```

Require passing recorded responses, zero failed requests, p95 within the candidate budget and measured dependency mock matching. The app, mock and generator share the machine: this measures the app against recorded dependencies on this runner, not production capacity. Use fresh replay output names for subsequent runs. Mock output, replay output and original traffic remain available for review; `make clean` only removes scratch files.

Stop mocks with Ctrl-C when done. For a visual view of healthy and faulted dependency calls, `make mock-chaos-record` retains a mixed run and `make web` opens the native Requests grid, whose Chaos column identifies injected failures. This optional mode is for viewing evidence, not proving all fallback states.

## Capture your own baseline

The local inventory fixture is needed only for a new capture:

```sh
make capture
```

This starts inventory, records six requests and stops its own processes. Output goes to `proxymock/recorded-local`; the committed recording is preserved. Repeating capture refuses to overwrite an existing directory. Use `make capture CAPTURE_DIR=proxymock/recorded-second` for another capture and `make mock RECORDING_DIR=proxymock/recorded-second` to use it.

The focused [agent task](AGENT_TASK.md) and [video script](DEMO-SCRIPT.md) use the same app and native commands. Dependency replacement, chaos and replay gates are existing proxymock features.
