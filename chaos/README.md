# Chaos + proxymock: reaching the fallback path on purpose

The storefront answers `GET /api/stock/{sku}` by asking an inventory service
how many units are on hand. If inventory is unavailable it falls back to the
last good answer it saw and marks the response `degraded`.

That fallback has never run. Nothing in the test suite makes inventory fail,
and inventory does not fail on request. The code is written, reviewed, and
merged, and whether it works is an open question that nobody has a cheap way
to close.

This lab closes it in one command. A scoped chaos rule makes **inventory and
only inventory** fail, every call, while the rest of the recording keeps
answering normally. The fallback path runs on demand, every run.

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
