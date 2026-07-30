---
name: proxymock-chaos-mock
description: Inject faults into a proxymock mock with native --fault flags so the downstream lies to your service on demand - 503s, 429s with Retry-After, corrupt or truncated bodies, per-endpoint latency, socket-level connection faults, and exact deterministic failure ratios via rate=F/N. Use when users ask to chaos-test a service against its dependencies, simulate a slow or failing downstream, test retry/backoff/timeout handling, or check what their app does when a dependency misbehaves.
argument-hint: --in <recording-dir> --fault '<regexp>:<action>=<value>' [-- <app command>]
---

# proxymock Chaos Mock

Turn a recording into a lying downstream. One native command:

```bash
proxymock mock --in ./proxymock/recording \
  --fault '/v1/projects:status=503' \
  -- <your app command>
```

The faults are process flags, not data. The recording is served AS IS: no copy,
no RRPair edits, no variant to validate, nothing to roll back. What you observe
is your service's resilience behavior, which is the point.

**Requires proxymock v2.5.814 or newer.** Connection faults in particular
differ on older builds.

## Works with your stack (no bash required)

`proxymock mock` is an HTTP proxy in front of your dependencies. Your app talks
to it over `--proxy-out-port` (default 4140) and nothing else in your stack
changes, so the driver hitting your app can be k6, bruno, postman-cli, curl,
your own integration suite, or a human clicking around.

```bash
# standalone: start the lying downstream, start your app separately against it
proxymock mock --in ./proxymock/recording --proxy-out-port 4140 \
  --fault '/v1/projects:status=429,header=Retry-After:30'

# or let proxymock wrap the app so the proxy env is wired for you
proxymock mock --in ./proxymock/recording \
  --fault '/v1/projects:connection=drop' -- go run .
```

`mock` runs until you stop it; there is no pass/fail exit code to gate on. The
gate is whatever you assert about your app *while* it serves — so pair it with
`proxymock replay` (proxymock-regression-test) or your own test driver. The
repo's `quality-loop.sh chaos` is optional convenience that builds this exact
line; the native command is the contract.

`proxymock mock` **requires an explicit `--in`** — it does not discover a
recording from cwd. Repeated `--in` unions several recordings into one
mock source set.

## Fault syntax

```
--fault '<RE2 pattern>:<action>=<value>[,<action>=<value>...]'
```

Repeatable. The pattern is **unanchored** and is matched against the **bare
path** and **host+path** only. Scheme, port and method are **not** in the
candidate string, so `'https://api.example.com:443/v1/projects'` parses fine,
starts fine, and matches nothing. Use a plain path substring like
`'/v1/projects'`.

Actions:

| Action | Value | Notes |
| --- | --- | --- |
| `status` | `NNN` | body left intact |
| `header` | `Name:Value` | `Name=Value` is rejected |
| `latency` | Go duration | **unit required**: `2500ms`, `1.5s`; bare `2500` is rejected |
| `rate` | `F/N` | deterministic and periodic; composes with any other action |
| `body` | `corrupt` \| `truncate[:bytes]` | corrupt = invalid JSON, truncate = well-formed but short |
| `connection` | `refuse` \| `reset` \| `stall` \| `drop` | socket-level, see below |

`rate=F/N` alone injects intermittent 503s. Only the `F/N` form is accepted:
`0.5` and `50%` are rejected at startup.

Responses carrying a `status=`, `header=`, `body=` or `latency=` fault are
tagged `x-speedscale-chaos: proxymock fault`; unfaulted responses carry
`x-speedscale-chaos: none`, so match on the value, not on presence. Connection
faults have no complete response to tag.

**A pattern that matches nothing warns where you are not looking.** proxymock
prints `Warning: --fault pattern "..." matches no mock data, so it will never
fire` — but when it **wraps your app**, its own output goes to `proxymock.log`,
not your terminal. Standalone mocks print it. Read the log before believing an
injected fault ran.

## What each connection fault looks like

All four fire over **HTTP/2** as well as HTTP/1.1, and stay scoped to the
endpoints the pattern matches: measured against the committed h2 recording,
`/v1/projects` failed under every action while an untargeted `/v1/categories`
kept its exact full 200 body. What differs is how the failure reaches you,
which decides what a test can assert:

- **`refuse` and `reset` are the same finding.** Both cut the connection before
  a complete response arrives, and a Go HTTP client reports both as
  `unexpected EOF`. At the socket level they differ (`curl` exits 52 vs 56),
  but nothing above the transport can tell which one was injected. Do not write
  an assertion that claims to.
- **`stall` only fails if the client has a timeout.** The mock accepts the
  request and never answers; without a client deadline the call hangs forever.
  Measured with `curl -m 8`: exit 28 at 8s. An app with no timeout hangs with
  it, which is itself the finding.
- **`drop` is the sharp one.** It truncates mid-stream, so the status line and
  headers are already on the wire: the response advertises a `Content-Length`
  it never delivers. The truncated length varies between runs, so assert that
  the body is short rather than on a number. A pass-through handler returns
  **HTTP 200 with a silently short body**, which a status-only assertion scores
  as a pass. **Assert on body length or content.** A handler that JSON-decodes
  the body surfaces the truncation as a 5xx instead.

## Faults are startup-only

`--fault` is read **once at startup**. Only mock DATA hot-reloads, via
`--mock-reload-interval 1s`, which picks up an RRPair edit in about a second.
Changing the fault set means restarting the mock.

That has a consequence for recovery scenarios: **restarting a mock that WRAPS
the app restarts the app too**, destroying whatever in-process state the
recovery was supposed to test. Run recovery scenarios with the mock
**un-wrapped** and the app started separately against `--proxy-out-port`.

## Ratio discipline

When the client-visible failure ratio IS the measurement, use `rate=F/N`. It is
exact and periodic: `rate=1/3` measured `503 200 200 503 200 200` over six
probes, so retry policies are testable exactly rather than statistically. With
`1/2` and one immediate retry every client call should succeed; a
client-visible failure rate equal to F/N means no retries at all.

`--response-selection random` exists but is **weighted by copy count and
noisy** — a 50% expectation measured 15/40 — which is useless as an analytical
instrument. Stay on the default `round-robin`, or use `rate=F/N`.

## What still needs file edits

Native faults replaced the whole variant-building engine, with one exception:
`body=` only does `corrupt` and `truncate`. Scenario-accurate payloads (a real
rate-limit envelope, a schema-drifted object) still need an RRPair edit, either
by hand or with the MCP `edit_rrpair` tool, which is **body-only** (`file`,
`side`, `body`).

## MCP parity

`mock_server_start` exposes `fault`, `mock-timing`, `mock-reload-interval` and
`response-selection` alongside `in-directory`, `out-directory` and `log-to`, so
faults themselves no longer need the CLI. Still absent over MCP:
**`proxy-out-port`, `health-port`, `app-health-endpoint`**. An MCP-only agent
can inject faults but cannot pin the proxy-out port or wait on a readiness
endpoint; shell out to the CLI for that.

## Interpretation

What the app under test does with each lie is the finding:

- **`status=503`**: an app that returns 200 from a dependent endpoint while the
  downstream 503s is swallowing errors. Observed in the lab app: it ignores the
  downstream status whenever the body still parses.
- **`status=429,header=Retry-After:30`**: check whether `Retry-After` survives
  to the app's own response. The lab app strips it, so its clients would never
  see the hint. An app that retries a 429 immediately is worse.
- **`body=corrupt`**: an endpoint that passes garbage through as 200 is
  proxying decode failures to its own clients; the resilient behavior is a 5xx.
- **`latency=<d>`**: watch the app's timeout budget. Under it, slow 200s; over
  it, whatever the app does instead is the finding.
- **`connection=drop`**: the defect class no file edit could ever surface —
  200 with a truncated body and no error anywhere in the chain. Gate on body
  length or content; status alone reports success.

## Related

- **proxymock-regression-test**: replay at the app while this faulted mock
  serves, to turn observed resilience behavior into a gate.
- **proxymock-perf-container**: drive load while the downstream is slow or
  flaky.
- **proxymock-verify-fix**: after fixing a resilience bug this exposed, prove
  the fix by replay.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

One shared proof covers this pack (a documented deviation from the repo's
one-prove-per-skill convention: every skill runs the same native binary now).
The cases covering this skill serve the UNMODIFIED committed recording and
verify proxy-observed behavior: `status=503` on the target with the untargeted
endpoint still 200 and the `x-speedscale-chaos` header present, `rate=1/3`
producing exactly `503 200 200 503 200 200`, and the scheme+port form of a
plausible pattern producing the no-match warning instead of a silent no-op.
