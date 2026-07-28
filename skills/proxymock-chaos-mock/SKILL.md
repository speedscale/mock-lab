---
name: proxymock-chaos-mock
description: Inject faults into a proxymock mock with native --fault flags so the downstream lies to your service on demand, including 503s, 429s with Retry-After, corrupt or truncated bodies, per-endpoint latency, socket-level connection faults, and exact deterministic failure ratios via rate=F/N. Use when users ask to chaos-test a service against its dependencies, simulate a slow or failing downstream, test retry/backoff/timeout handling, or check what their app does when a dependency misbehaves.
argument-hint: --in <recording-dir> --scenario down|ratelimit|garbage|slow|connection|flaky --target <path-regexp> [--latency 2500ms] [--ratio 1/3] [--retry-after 30] [--connection reset] [--serve] [--restore]
---

# proxymock Chaos Mock

Turn a recording into a lying downstream. Given a healthy recording and one
target endpoint pattern, this skill builds the right `proxymock mock --fault`
flags and runs the mock, so your service can be exercised against a
downstream that is slow, erroring, rate-limiting, garbled, socket-broken, or
intermittently failing. The faults live in the mock, not the app: what you
observe is your service's resilience behavior, which is the point.

Faults are process flags, not data. The recording is served AS IS: no copy,
no RRPair edits, no variant to validate, nothing to roll back. Every mocked
response carries `x-speedscale-chaos`, valued `proxymock fault` when a fault
fired and `none` when it did not, so match on the value, not on presence.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the recording directory to serve. Never modified.
- `--scenario`, and the fault spec it builds:
  - `down`: `status=503`, body intact.
  - `ratelimit`: `status=429,header=Retry-After:<n>` (`--retry-after`,
    default 30). Header syntax is `Name:Value`; `Name=Value` is rejected.
  - `garbage`: `body=corrupt`, or `--body-fault truncate` /
    `truncate:BYTES` for a well-formed but short body.
  - `slow`: `latency=<duration>` per endpoint. `--latency` takes a Go
    duration and the UNIT IS REQUIRED (`2500ms`, `1.5s`; a bare `2500` is
    rejected). `--latency Nx` instead uses the global `--mock-timing`
    multiplier, which slows every mocked endpoint and makes `--target`
    advisory.
  - `connection`: `connection=refuse|reset|stall|drop` (`--connection`,
    default `reset`). Read "what each connection fault looks like" below:
    the four are not interchangeable, and `drop` needs a different
    assertion than the rest.
  - `flaky`: `status=503,rate=F/N` (`--ratio`, default `1/2`).
- `--target`: the fault regexp (RE2), and the single most common source of
  faults that do nothing. It is **unanchored** and matched against the
  **bare path** and **host+path**. Scheme, port, and **method** are not in
  the candidate string, so `'https://api.example.com:443/v1/projects'`
  parses fine, starts fine, and matches nothing. Use a plain path substring
  like `'/v1/projects'`. The script pre-checks the pattern against the
  loaded outbound pairs and exits 2 rather than serving a silent no-op.
  proxymock warns about this itself now (`Warning: --fault pattern ...
  matches no mock data, so it will never fire`), but only where its own
  output goes: a mock that WRAPS your app (`-- go run .`) redirects that
  output to `proxymock.log`, so the warning never reaches the terminal.
  Standalone mocks print it. The pre-check is the signal that always shows
  up.
- `--ratio F/N`: composes with any scenario, so
  `--scenario ratelimit --ratio 1/3` is a 429 on the first request of every
  three. Only the `F/N` form is accepted by proxymock: `0.5` and `50%` are
  rejected at startup.
- `--serve`: start the faulted mock in the background, un-wrapped, and leave
  it running; state lands in `<work-dir>/serve.json`. Without it the script
  prints the exact `proxymock mock ... --fault ...` command to run yourself.
- `--restore`: stop the faulted mock recorded in `--work-dir` and restart it
  fault-free on the same ports.
- `--custom-body FILE` / `--flip-body FILE`: RRPair-level body control, see
  "What still needs file edits".
- `--proxy-out-port` / `--health-port` / `--reload-interval` / `--work-dir` /
  `--proxymock`: ports, hot-reload interval (default `1s`), state location,
  binary path.

Run the bundled script:

```bash
# downstream 503s on one endpoint; serve the lying mock
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --in ./proxymock/recording --scenario down --target '/v1/projects' --serve

# exact 1-in-3 deterministic 429s with a Retry-After hint
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --in ./proxymock/recording --scenario ratelimit --target '/v1/projects' \
  --ratio 1/3 --serve

# put the healthy downstream back
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --restore --work-dir ./proxymock-chaos-20260724T000000Z
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-chaos-mock` with the copied skill directory. The scripts
source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## What each connection fault looks like

All four fire regardless of the recorded protocol, HTTP/2 included, and only
on the endpoints `--target` matches: measured against the committed h2
recording, `/v1/projects` failed under every action while an untargeted
`/v1/categories` kept returning its full 200 body.

What differs is how the failure reaches you, which decides what a test can
assert:

- **`refuse` and `reset` are the same finding.** Both cut the connection
  before a complete response arrives, and a Go HTTP client reports both as
  `unexpected EOF` (the lab app turns that into a 502). At the socket level
  they are distinguishable (`curl` exits 52 vs 56), but nothing above the
  transport can tell you which one was injected, so do not write an
  assertion that claims to.
- **`stall` only fails if the client has a timeout.** The mock accepts the
  request and never answers; without a client deadline the call hangs
  forever. Measured with `curl -m 8`: exit 28 at 8s. An app with no timeout
  hangs with it, which is itself the finding.
- **`drop` is the sharp one.** It truncates mid-stream, so the status line
  and headers are already on the wire: a pass-through handler returns
  **HTTP 200 with a silently short body**. Through the mock's proxy port the
  response advertises `Content-Length: 17` and delivers 7 bytes (`curl` exit
  18); through an app that copies the body onward, clients get a
  syntactically plausible fragment with no error anywhere in the chain.
  **Assert on body length or content, not on status.** A handler that
  JSON-decodes the body surfaces the truncation as a 5xx instead.

`x-speedscale-chaos: proxymock fault` tags responses carrying a `status=`,
`header=`, `body=`, or `latency=` fault. Connection faults have no complete
response to tag, so do not look for the header there.

## What still needs file edits

Native faults replaced the whole variant-building engine, with two
exceptions:

- **Custom bodies.** `body=` only does `corrupt` and `truncate`.
  Scenario-accurate payloads (a real rate-limit envelope, a schema-drifted
  object) still need an RRPair edit. `--custom-body FILE` makes a writable
  copy of the recording in `<work-dir>/recording`, rewrites the matched
  pairs' response bodies, and serves the copy. Content-Length is recomputed
  by the responder, so it does not need to be touched. The MCP `edit_rrpair`
  tool does the same thing one pair at a time.
- **Mid-session flips.** `--fault` is read **once at startup**; only mock
  DATA hot-reloads. `--flip-body FILE` rewrites the serving copy's bodies
  while the mock keeps running and `--mock-reload-interval` (default `1s`)
  picks the change up in about a second; restoring the file recovers about
  as fast. Anything that changes the FAULT set is a restart, which is what
  `--restore` does.

Because removing a fault means restarting the mock, run recovery scenarios
with the mock **un-wrapped** (`--serve`) and the app started separately
against the proxy port. A mock that wraps your app (`proxymock mock -- app`)
restarts the app when it restarts, which destroys whatever in-process state
the recovery was supposed to test.

## Ratio discipline

When the client-visible failure ratio IS the measurement, use `rate=F/N`
(`--ratio`) or duplicate-signature round-robin. `--response-selection random`
exists but is weighted by copy count and noisy: a 50% expectation measured
15/40 in practice, which is useless as an analytical instrument. The script
always serves with `--response-selection round-robin`.

## MCP parity

Every chaos knob is CLI-only. The `mock_server_start` MCP tool takes only
`in-directory`, `out-directory`, and `log-to`: no `fault`, no `mock-timing`,
no `response-selection`, no `mock-reload-interval`, no `app-health-endpoint`,
not even `proxy-out-port`. `edit_rrpair` is body-only. An MCP-only agent
cannot run this skill; shell out to the CLI.

## Output contract

Without `--serve` the script prints the matched endpoints and the exact
`proxymock mock --fault` command. With
`--serve` it writes `serve.json` (pid, ports, the fault specs in use, the
served and source recordings) and `mock.log` to `--work-dir`, plus
`recording/` when `--custom-body` forced a copy.

Exit codes:

- `0`: fault command ready (and serving, if `--serve`); flip or restore done.
- `2`: `--target` matched no loaded outbound pair. A fault regexp that
  matches nothing is a silent no-op, so this is a correctness gate, not a
  nicety; the available endpoints are listed.
- `3`: the mock did not come up (see `mock.log`).
- `4`: precondition or usage failure, including fault specs proxymock would
  reject (`--latency` without a unit, `--ratio 50%`, an unknown
  `--connection` action).

## Interpretation

What the app under test does with each lie is the finding:

- **down**: an app that returns 200 from a dependent endpoint while the
  downstream 503s is swallowing errors. Observed in the lab app: it ignores
  the downstream status code whenever the body still parses, which is
  exactly the class of bug this scenario exists to expose.
- **ratelimit**: check whether `Retry-After` survives to the app's own
  response. An app that strips it breaks client backoff (the lab app strips
  it; its clients would never see the hint). An app that retries a 429
  immediately is worse.
- **garbage**: a dependent endpoint that passes garbage through as 200 is
  proxying decode failures to its own clients; the resilient behavior is a
  5xx from the app when the downstream body fails to parse.
- **flaky**: because `rate=F/N` is exact and periodic, retry policies are
  testable exactly, not statistically. With `1/2` and one immediate retry,
  every client call should succeed; a client-visible failure rate equal to
  F/N means no retries at all.
- **slow**: watch for the app's timeout budget. Under the app's timeout you
  should see slow 200s (latency propagated); over it, whatever the app does
  instead (5xx, hang, fallback) is the finding. A `stall` connection fault
  finds the same bug harder: the lab app has no client timeout at all and
  hangs forever.
- **connection=drop**: the defect class no file edit could ever surface. The
  response advertises `Content-Length: 17` and writes 7 bytes. An app that
  ignores the `io.ReadAll` error returns 200 with a truncated body, so its
  clients get a short, syntactically plausible payload with no error
  anywhere in the chain. A gate built on this scenario has to compare body
  length or content; status alone reports success.

## Related

- **proxymock-regression-test**: run it against the app while this skill's
  faulted mock is serving to turn observed resilience behavior into a gate.
- **proxymock-load-test**: drive load at the app while the downstream is
  slow or flaky to see resilience under pressure.
- **proxymock-verify-fix**: after fixing a resilience bug this skill
  exposed, capture the incident and prove the fix by replay.

## Proof

```bash
./skills/proxymock-chaos-mock/scripts/prove-proxymock-chaos-mock.sh
```

The proof is hermetic (no cloud, no live downstream, no app build) and runs
against the committed recording without modifying it. It serves each fault
natively and verifies proxy-observed behavior: a 503 on the target with the
untargeted endpoint still healthy and the `x-speedscale-chaos` header
present; a 429 carrying `Retry-After: 30`; `rate=1/3` producing exactly
`503 200 200 503 200 200`; a `latency=500ms` fault delaying only the target;
and a fault-free downstream after `--restore` on the same port. It then
proves connection faults fire on the committed recording, which is HTTP/2:
against a same-port fault-free control, `connection=reset` breaks the target
request at the transport while the untargeted endpoint keeps its full body,
and `connection=drop` returns a 200 whose body is shorter than the control's.
The silent no-op is still gated: the scheme+port form of a plausible pattern
exits 2 with the matching rules explained.
