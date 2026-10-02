# Chaos + proxymock: reaching the fallback path on purpose

The storefront answers `GET /api/stock/{sku}` by asking an inventory service
how many units are on hand. If inventory is unavailable it falls back to the
last good answer it saw and marks the response `degraded`.

The tests exercise transport and decode errors, but none makes inventory return a non-2xx status with a valid body. That condition matters because the client currently accepts any parseable body, including one returned with a 503 status.

The failure takes one command to reproduce. A scoped chaos rule makes **inventory and only inventory** fail, every call, while the rest of the recording keeps answering normally. After the status bug is fixed, the fallback path can be rerun on demand.

The sibling [Loki lab](../loki) tells the same kind of story from the other
side: there, the rare dependency response had to be present in the traffic on
the day it was captured. Here you do not need that luck.

The lab is checked in with the bug. Read the evidence, find the unhandled
failure, make the smallest fix, and prove the storefront degrades honestly.

## Prerequisites

- Go 1.23 or newer, `curl`
- proxymock 2.5.876 or newer, installed, initialized, and on `PATH`
- No Docker, no cluster, no Speedscale account. Every command below is local.

Run everything from this `chaos` directory of your `mock-lab` clone. The
storefront binds `127.0.0.1:8080` and the inventory fixture `localhost:8090`,
matching the neighboring labs; proxymock's health endpoint is on `4141` and
its proxy on `4140`.

## Coverage is not a behavior check

Run `make coverage` before the chaos case. The current suite reports 77.6% statement coverage for the app package and 100.0% for `fetchStock`. It exercises successful JSON decoding, malformed JSON, and a transport error. It never checks an HTTP 503 that still carries valid JSON, so the client reports success and the fallback stays untested.

The coverage report is accurate about the code the tests executed. The missing part is an assertion about the dependency status and the storefront contract. The exercise below makes that omission visible with a controlled 503.

The full demo run of show is in [`DEMO-SCRIPT.md`](DEMO-SCRIPT.md).

## 1. Record one ordinary session

```shell
make capture
```

The inventory fixture starts, `proxymock record` runs the storefront as a
child, six SKUs are looked up through proxymock's inbound reverse proxy on
`4143`, and everything stops. You get 6 inbound stock lookups and 6 outbound
inventory calls.

Nothing rare is in this recording, deliberately. Every SKU resolves, inventory
answers `200` every time, and there is no failure anywhere in it.

## 2. Watch the storefront work

```shell
make mock          # leave running
make baseline      # in a second terminal
```

Six healthy answers, `degraded:false`, `source:"inventory"`. This is the state
every test suite has ever seen.

## 3. Take inventory down, and nothing else

Stop `make mock`, then:

```shell
make mock-chaos    # leave running
make baseline      # in a second terminal
```

The rule is one flag:

```
--chaos '(url CONTAINS "/v1/inventory"): status=503,percent=100'
```

The scope is a filter query — the same syntax the Requests grid and
`--query-string` use, and every group must be parenthesized. It selects the
outbound inventory calls and nothing else.

Now compare what the storefront says with what inventory actually did:

```shell
make chaos-evidence
```

Inventory is answering `503 Service Unavailable` on every call, and says so:

```
HTTP/1.1 503 Service Unavailable
X-Speedscale-Chaos: effect=status code;status=503;rule=chaos-1
```

The `x-speedscale-chaos` header is how you tell an injected failure from a
real one. It names the effect and the rule that fired, it is absent on
untouched responses, and it is persisted onto the recorded pair, so it is
visible later in proxymock-web as well as on the wire.

And the storefront's answer to all six SKUs, with its only dependency
completely down:

```
{"sku":"SSC-4110","available":42,"in_stock":true,"degraded":false,"source":"inventory"}
```

`degraded:false`. `source:"inventory"`. No warning in the log. The fallback
cache — which exists, and is correct — never ran.

## 3b. See it in proxymock web

The header on the wire is one view. The other is the run itself.

Stop `make mock-chaos` and start a run that writes what it serves — the
earlier targets pass `--no-out` so repeat runs do not pile up result
directories, and here the output is the point:

```shell
make mock-chaos-record    # leave running
make baseline             # a few times, in a second terminal
```

Then, in a third terminal:

```shell
make web
```

Open `http://127.0.0.1:7788` and go to Requests. The **Chaos** column marks
every perturbed response, the toolbar filter narrows to just those, and
opening one shows which rule fired and what it changed.

This variant uses `percent=50`, so the grid holds both kinds of row and the
filter has something to do. That is the view worth having: injected failures
are labelled, so an injected 503 is never mistaken for a real one.

**The STATUS column shows what the client actually received** — `503` on
chaosed rows — with a tooltip reading `Chaos sent 503; the mock recorded 200`.
Both numbers are true and the grid keeps both: the recorded pair deliberately
holds its pre-chaos status, because that pair is mock input for a later run
and rewriting it would change what a re-replay does. A response chaos withheld
entirely shows `—` rather than a status.

So the file on disk and the `/api/rrpairs` field say `200` while the cell says
`503`. That is the intended split, not a disagreement.

## 4. Find it

The evidence is in [`evidence/broken-storefront.jsonl`](evidence/broken-storefront.jsonl)
if you want to read it without running anything.

Two facts to reconcile:

- inventory returned `503` on every call, with the chaos marker to prove it
- the storefront reported fresh data from inventory, undegraded, for every SKU

Nothing in the response contract changed, which is why no status assertion and
no response diff would have caught this. The numbers are even *right* — they
are the recorded body, which a 503 does not erase. The lie is the metadata:
the storefront told its callers this data was current when its dependency was
down.

`AGENT_TASK.md` is the same exercise pointed at a coding agent.

## 4b. Measure the slow dependency path

The service requirement for this lab is that a stock lookup finishes within 750 ms when inventory stalls. Start `make mock-slow`, then run `make slow-evidence` in another terminal. The injected inventory response takes 2 seconds. The current 5-second client timeout lets it complete, which violates this demo service objective of 750 ms. The command reports the storefront's actual elapsed time. Ask the agent to set a suitable client timeout and verify the request returns before the 750 ms limit.

After the timeout fix, test under recorded request load from a healthy mock with a p95 gate:

```shell
proxymock replay --in proxymock/recording --test-against http://127.0.0.1:8080 \
  --vus 4 --for 10s --fail-if 'latency.p95>750' --fail-if 'requests.failed!=0'
```

Use the p95 check as a regression gate on the same runner. Local replay can be limited by the mock and traffic generator, so do not present its RPS as the service's capacity. For capacity numbers, run the generator away from the app and mock.

## 5. Prove the fix

After fixing, run the flaky variant rather than the total outage:

```shell
make mock-flaky    # leave running
make baseline      # a few times, in a second terminal
```

```
--chaos '(url CONTAINS "/v1/inventory"): status=503,percent=50,seed=lab'
```

Half the calls fail, so one run exercises the healthy path, the degraded path,
and the transition between them. A fixed storefront answers with all three
states and never claims `degraded:false` on a call that failed:

```
{"error":"inventory unavailable"}                                    first call, nothing cached yet
{"sku":"SSC-4110","available":42,...,"degraded":false,"source":"inventory"}
{"sku":"SSC-4110","available":42,...,"degraded":true,"source":"cache"}
```

## On reproducibility

`seed=lab` makes the run repeatable, with a limit worth stating plainly.

The roll is a pure function of the rule, the request signature, and the
occurrence count — the Nth lookup of a given SKU always gets the same verdict.
It is **not** a promise that two runs are bit-identical: a run that issues a
different number of requests for a signature diverges after that point. That
is stronger than ordering-based reproducibility, which is worthless when the
responder serves requests concurrently, and weaker than full determinism.

In practice it means a failure you find this way is one you can hand to a
teammate with the command that produced it.

## What this does not do

It does not hide the consequences. If the storefront cannot absorb an injected
failure, the failure is reported normally — that is the entire question you
came to answer. Chaos-affected traffic is excluded from drift and match-rate
analysis, because an injected 503 is not mock drift, but never from pass/fail.
