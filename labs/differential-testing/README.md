# Compare two builds when you can't call the dependencies

This lab runs a differential test on a small checkout service. The same twelve recorded requests go to the current build and to a changed build, and the responses are compared. The service depends on a product catalog and a payment processor. Neither one is running during the test. proxymock answers for both from the recording.

The changed build passes its unit tests. Replayed against the recording, it fails two checkouts:

```text
NEW MISMATCH: POST /api/checkout recorded 201 -> observed 402
NEW MISMATCH: POST /api/checkout recorded 503 -> observed 402
```

The first is a customer who paid in the recording and is declined by the new build. The second is a payment processor outage that the new build reports to the customer as a declined card.

## What's in the recording

Twelve inbound requests and the 23 dependency calls the service made to answer them: 18 to the catalog and 5 to the payment processor. Two of the recorded payment calls are failures you could not ask a real processor to produce on demand, a declined card (402) and a processor outage (503).

The traffic is synthetic. It was captured once against the stand-in catalog and processor in `fixture/`, which exist only for capture. `candidate.patch` supplies the changed build so the result is repeatable.

## Set up

Install [Go 1.23 or newer](https://go.dev/doc/install) and [proxymock](https://docs.speedscale.com/proxymock/getting-started/installation/), then activate it with `proxymock init`. Clone mock-lab and enter this lab:

```bash
git clone https://github.com/speedscale/mock-lab.git
cd mock-lab/labs/differential-testing
```

The app listens on port 8080 and proxymock on 4140. No Docker, database or cluster is needed.

## Save a baseline from the current build

In terminal 1, start the service with both dependencies mocked from the recording:

```bash
proxymock mock --in proxymock/recording --no-passthrough --out proxymock/results/mocked-current -- go run .
```

`--no-passthrough` makes a call that is not in the recording fail, so the service can't reach a real catalog or processor by accident.

In terminal 2, replay the recorded requests and keep the result:

```bash
proxymock replay --in proxymock/recording --test-against localhost:8080 --out proxymock/results/baseline
```

The replay ends with `Replay verdict: proxymock/results/baseline/replay-verdict.json (pass)`. Order IDs and timestamps differ on every run and are left out of the comparison.

## Apply the change

`candidate.patch` is a refactor of the pricing helper and the payments client. Apply it and run the unit tests:

```bash
git apply candidate.patch
go test ./...
```

The tests pass. They price a cart with round numbers and exercise one successful payment.

## Replay the same requests against the changed build

Stop terminal 1 with Ctrl-C and start the changed build under the same mocks:

```bash
proxymock mock --in proxymock/recording --no-passthrough --out proxymock/results/mocked-candidate -- go run .
```

In terminal 2, replay against the baseline with the gate on:

```bash
proxymock replay --in proxymock/recording --test-against localhost:8080 --baseline proxymock/results/baseline --fail-on-new-mismatch --out proxymock/results/candidate
```

The command prints the two mismatches above and exits 3.

## Read what changed

The first mismatch comes from the price. The mock's log shows the charge the new build tried to make next to the one in the recording:

```bash
grep -A 12 "NO MATCH" proxymock/results/mocked-candidate/proxymock.log
```

```text
< http:requestBodyJSON: {"amount_cents":13856,"card_token":"tok_amex","currency":"USD"}
> http:requestBodyJSON: {"amount_cents":13857,"card_token":"tok_amex","currency":"USD"}
```

The refactor moved tax into floating point and truncates it. For this cart the tax drops from 9.07 to 9.06, so the service asks the processor for 138.56 where the recorded charge was 138.57. No recorded charge matches that amount, and the checkout fails.

The second mismatch comes from error handling. In the recording the processor answers 503 and the service returns 503 with `"status": "payment_unavailable"` and `"retryable": true`. The refactored client turns every failed charge into an error, and the handler reports every error as a declined card.

Neither case is in the unit tests. Both are in the recorded traffic.

## Repair it and replay again

Fix the two problems yourself, or apply the supplied repair on top of the candidate:

```bash
git apply repair.patch
go test ./...
```

Restart terminal 1 with the mock command, then repeat the gated replay with `--out proxymock/results/repaired`. Keep the original baseline. All twelve requests pass and the command exits 0.

| Build | Unit tests | Gated replay |
| --- | --- | --- |
| Current | Pass | Baseline passes |
| `candidate.patch` | Pass | Two new mismatches, exit 3 |
| `repair.patch` | Pass | Twelve requests pass, exit 0 |

The [replay verdict guide](https://docs.speedscale.com/proxymock/guides/replay-verdicts/) explains the status and body checks and the exit codes.

## Capture a new recording

The committed recording is all the steps above need. To capture your own, run:

```bash
RECORDING_DIR=proxymock/recorded-local scripts/capture.sh
```

The script starts the fixture on ports 8091 and 8092, records the service through proxymock's inbound port 4143, sends the requests in `scripts/traffic.sh`, and stops everything it started. Pass `--in proxymock/recorded-local` to use the new recording.

A recording covers the requests that are in it. Keep tests for behavior outside the recording, and re-record when a dependency changes its responses.
