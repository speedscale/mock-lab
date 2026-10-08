# Storefront verification lab

Use recorded inventory traffic and the app's requirements to evaluate a small Node storefront with the proxymock skills. The app, inventory fixture, tests and committed recording are the starting inputs. Let the skills inspect them, choose scenarios and collect evidence.

You need Node 24+ (or 22.21+), initialized proxymock v2.5.1133 or newer, make and curl. No npm packages, Go, Docker, database or cluster are needed. From the repository root, run `cd labs/chaos`. The app uses port 8080, inventory 8090 and proxymock 4140/4141/4143; run one session at a time.

## Requirements

- A healthy inventory result must preserve the SKU and availability and identify inventory as its source.
- Previously cached inventory may be served when fresh inventory is unavailable. The response must identify the cache as its source and mark the data degraded.
- When usable inventory is unavailable and nothing is cached, return HTTP 503 with an error response.
- The candidate local response budget is 750 ms, including dependency failures. Review this budget before accepting it as a test baseline.

These requirements define expected behavior. The recording contains observed traffic; it is not the complete set of requirements.

## Setup

The committed recording contains six stock reads and six inventory calls and works offline. Start the app with the recorded dependency:

```sh
make mock
```

In another terminal, send the ordinary stock reads:

```sh
make baseline
```

Stop the mock with Ctrl-C when finished. Native mock evidence stays under ignored `proxymock/results/healthy`. The Makefile enables Node's built-in proxy support and clears loopback proxy exclusions so local inventory calls reach the mocks. Only local HTTP is used.

Run the existing tests and inspect coverage:

```sh
npm test
make coverage
```

The CI job runs the existing tests and reports coverage. Use their assertions and observed results to determine what they establish about the requirements.

## Capture a new input

The local inventory fixture is needed only for capture:

```sh
make capture
```

This starts inventory, records six requests and stops its own processes. Output goes to `proxymock/recorded-local`; the committed recording is preserved. Existing output is never overwritten. Choose a fresh directory for another capture, for example `make capture CAPTURE_DIR=proxymock/recorded-second`. Use `make mock RECORDING_DIR=proxymock/recorded-second` to run with it.

Install the [proxymock skills](https://github.com/speedscale/skills), start your agent in this lab directory and give it the [verification task](AGENT_TASK.md). Keep accepted expectations and run output with the tests it creates. The repository does not prescribe the scenarios, fault rules, diagnosis or fix.
