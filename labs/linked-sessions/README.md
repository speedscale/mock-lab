# See one shopper as one actor when their session ID changes

This lab records a small storefront whose users change session ID on the way through it, then shows proxymock web putting each user's session IDs back together as one actor.

A shopper signs in with a JWT that carries their user ID, so the storefront's own request is keyed by `u-alice-1001`. The storefront calls the payment service with a token of its own that names her only by its `sub` claim, so that call is keyed by the token. Her browser comes back later with nothing but a `jsessionid` and the payment ID it was given. That is three session IDs for one person, and before linked sessions the Sessions tab showed three actors.

## What's in the recording

Nine requests to the storefront and the eight calls it made to the payment and order services:

| Who | What they did | Session ID on the storefront | Session ID on the dependency call |
| --- | --- | --- | --- |
| Alice | Checks out | `u-alice-1001` (JWT `uid`) | the storefront's JWT (`sub` is `u-alice-1001`) |
| Alice's browser | Polls her payment | `js-alice-77aa21` | none |
| Alice's email | Opens the receipt link | none | none |
| Bob | Checks out, then polls from his browser | `u-bob-2002`, `js-bob-5c31d0` | the storefront's JWT (`sub` is `u-bob-2002`) |
| Carol's browser | Lists her orders, with a `traceparent` header | `js-carol-4411` | partner token `ptk-dd6c7d9f593f` |
| Dave | Opens an internal tool with Basic auth | `dave.ops` | none |
| A support tool | Looks up Alice's and Bob's payments together | none | none |

Every client also reads `/api/config` and then sends the same `X-Tenant-Id: tenant-acme-001` on every call.

The traffic is synthetic. It was captured once against the stand-in payment and order services in `fixture/`, which exist only for capture.

## Set up

Install [Go 1.23 or newer](https://go.dev/doc/install) and [proxymock](https://docs.speedscale.com/proxymock/getting-started/installation/), then activate it with `proxymock init`. Clone mock-lab and enter this lab:

```bash
git clone https://github.com/speedscale/mock-lab.git
cd mock-lab/labs/linked-sessions
```

No Docker, database or cluster is needed.

## Open the recording

Start proxymock web on the committed recording and open the URL it prints:

```bash
proxymock web --in proxymock/recording
```

Select **Sessions** in the left nav. The **Actors** view shows five rows:

```text
LINKED  u-alice-1001     3 keys · linked by identity (jwt sub → session key), minted (response body paymentId → path segment) · +4 with no session
LINKED  u-bob-2002       3 keys · linked by identity (jwt sub → session key), minted (response body paymentId → path segment) · +2 with no session
        — unattributed —
LINKED  js-carol-4411    2 keys · linked by trace (trace id)
        dave.ops
```

Select Alice's row. The journey shows her checkout, the storefront's call to the payment service, her browser's poll and the receipt, in time order, as one person.

## Read why each pair was linked

Hover over a linked row to see its member keys and each link.

**Same identity.** The storefront's token for the payment service names Alice in its `sub` claim, and her own requests are keyed by the same value from her JWT's `uid` claim. The link reads `identity (jwt sub → session key)`.

**ID from an earlier response.** The payment service created `pay-…` in its response to the storefront, and Alice's browser later sent that ID back in its request path. The link reads `minted (response body paymentId → path segment)`. An ID links keys only when a later request sends it back, and only when the responses that created it belong to one request chain. The storefront relays the payment ID in its own checkout response at the same moment, so that counts as one creation.

**Same trace.** Carol's browser sends a `traceparent` header, and the storefront passes it to the order service with Carol's partner token. Both calls carry the same trace ID.

The links chain. Alice's browser shares nothing with her `u-alice-1001` requests directly, but it shares the payment ID with the storefront's token, and the token shares her identity with her requests.

## Requests with no session

Four requests send Alice's payment ID with no session ID: her receipt link, and the storefront's three calls that fetch her payment from the payment service (for her browser, for the receipt and for the support tool). Each one joins her actor because every value it carries points to her alone, so her row shows `+4 with no session` and her journey includes them. Their session ID stays empty.

The support tool's lookup sends Alice's and Bob's payment IDs together. It points to two people, so it stays in the unattributed row with the `/api/config` read.

## What stays apart

Everyone sends `tenant-acme-001`, and the storefront handed it out in one response, yet nobody is linked by it. A value seen under more than four session IDs is shared state, so it links nothing. Dave shares no identity, trace or ID with anyone, so his row stands alone.

The recorded session IDs never change. Filters, replay and load groups keep using them. When you add Alice's linked row to a load group, the group selects her three recorded session IDs.

## The same view in Speedscale

Speedscale links session IDs the same way when it analyzes a snapshot. Open the snapshot's **Traffic** tab and select **Sessions** to see linked actors and what linked them. The [linked sessions guide](https://docs.speedscale.com/guides/linked-sessions/) covers the rules and limits.

## Capture a new recording

The committed recording is all the steps above need. To capture your own, run:

```bash
RECORDING_DIR=proxymock/recorded-local scripts/capture.sh
```

The script starts the fixture on ports 8091 and 8092, records the storefront through proxymock's inbound port 4143, sends the requests in `scripts/traffic.sh`, and stops everything it started. Payment and order IDs are random, so a new recording has different ones. Pass `--in proxymock/recorded-local` to open it.
