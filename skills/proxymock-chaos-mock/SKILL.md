---
name: proxymock-chaos-mock
description: Inject faults into a proxymock mock by editing a COPY of the recording, so the downstream lies to your service on demand, including latency, 503s, 429s with Retry-After, garbage bodies, and exact deterministic flaky ratios via duplicate-signature round-robin. Use when users ask to chaos-test a service against its dependencies, simulate a slow or failing downstream, test retry/backoff/timeout handling, or check what their app does when a dependency misbehaves.
argument-hint: --in <recording-dir> --scenario slow|down|ratelimit|garbage|flaky --target <endpoint-or-regex> [--latency 5x|2500ms] [--ratio 1/2] [--retry-after 30] [--serve] [--restore]
---

# proxymock Chaos Mock

Turn a recording into a lying downstream. Given a healthy recording and one
target endpoint (or endpoint pattern), this skill builds a CHAOS VARIANT of
the mock data and runs the mock with it, so your service can be exercised
against a downstream that is slow, erroring, rate-limiting, garbled, or
intermittently failing. The faults live in the mock, not the app: what you
observe is your service's resilience behavior, which is the point.

The source recording is NEVER mutated: every edit happens on a copy in the
work dir. That is not just hygiene: one malformed RRPair aborts the ENTIRE
mock at load ("failed to parse response line" kills the whole directory), so
the skill validates every variant with a mock dry-start before declaring it
ready. Empirically verified.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the source recording directory (read-only; the variant is a copy).
- `--scenario`: one of:
  - `slow`: inject latency. `--latency Nx` (e.g. `5x`) is proxymock's native
    `--mock-timing` multiplier: no file edits, but GLOBAL, it slows every
    mocked endpoint. `--latency Nms` (e.g. `2500ms`) edits the `duration`
    metadata of the target pairs and serves with `--mock-timing recorded`,
    giving per-endpoint latency. Both empirically verified (600ms configured
    was observed as 604ms).
  - `down`: rewrite the recorded status to 503, body intact. The status
    lives in THREE consistent representations in the RRPair file: the
    visible status line, the internal `"status":"NNN"`, and
    `"statusCode":NNN,"statusMessage":...`; the script edits all three.
  - `ratelimit`: status to 429 plus a `Retry-After: <n>` response header.
  - `garbage`: keep the 200 but truncate/corrupt the body. Body replacement
    is the mechanism; do not bother lying about `Content-Length`, the
    responder recomputes and sanitizes it silently.
  - `flaky`: duplicate the target RRPair into N copies and edit F of them to
    503. Duplicate-signature RRPairs serve round-robin, DETERMINISTICALLY,
    in timestamp order: F/N is an exact periodic failure ratio (1/3 serves
    exactly 503, 200, 200, 503, 200, 200, ...), not a probability. The
    edited copies get the earliest timestamps, so the period starts with the
    faults.
- `--target`: regex matched against the outbound request URI (e.g.
  `'^/v1/projects'`). All matching pairs are edited (duplicates included),
  so `down` means down every time, not intermittently.
- `--ratio F/N`: flaky only (default `1/2`).
- `--retry-after N`: ratelimit only (default `30`).
- `--serve`: after validation, start the chaos mock in the background
  (standalone, no wrapped app) and print how to point your app at it. The
  mock keeps running after the script exits; state lands in
  `<work-dir>/serve.json`. To run your app WRAPPED by the chaos mock
  instead, use the printed `proxymock mock --in <variant> -- <your app>`
  command in the foreground.
- `--restore`: stop the serving chaos mock recorded in `--work-dir` and
  restart the mock from the ORIGINAL healthy recording on the same ports.
- `--proxy-out-port` / `--health-port`: ports for `--serve` (defaults: 4140
  and a free port).
- `--work-dir`: where the variant, `manifest.json`, and serve state land.
- `--proxymock`: proxymock binary path.

Run the bundled script:

```bash
# downstream 503s on one endpoint; serve the lying mock
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --in ./proxymock/recording --scenario down --target '^/v1/projects' --serve

# exact 1-in-3 deterministic failures
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --in ./proxymock/recording --scenario flaky --target '^/v1/projects' \
  --ratio 1/3 --serve

# put the healthy downstream back
./skills/proxymock-chaos-mock/scripts/proxymock-chaos-mock.sh \
  --restore --work-dir ./proxymock-chaos-20260723T000000Z
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-chaos-mock` with the copied skill directory. The scripts
source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Not supported (do not fake these)

- **Connection-level faults**: refuse, reset, stall, and mid-response drop
  are not achievable through mock data. A corrupted status line does not
  simulate a broken connection; it makes the whole directory fail to load
  (fail-closed), and a short-body `Content-Length` lie gets sanitized by the
  responder. Probed and confirmed absent.
- **Hot reload**: mock data loads once at startup. Restoring healthy files
  mid-session changes nothing (verified: still 503 seconds after the files
  were restored); recovery scenarios are stop mock, restore healthy variant,
  restart, which is what `--restore` does. If your app is WRAPPED by the
  mock (`proxymock mock -- app`), that restart restarts the app too; the
  standalone `--serve` pattern restarts only the mock.
- **MCP parity**: the `mock_server_start` MCP tool does not expose
  `--mock-timing`, so the slow scenario is CLI-only.
- **Randomness**: flaky is deterministic round-robin, timestamp-ordered.
  There is no weighted or random response selection.

## Output contract

Written to `--work-dir` (default a timestamped dir): `chaos-recording/` (the
variant; point `proxymock mock --in` at it), `manifest.json` (scenario,
target, every file edited with original values, mock-timing flag, validation
result), `validate.log` (the dry-start log), and with `--serve` also
`serve.json` (pid and ports) and `mock.log`. The script prints the variant
path and exact instructions for pointing the app at the mock (proxy env vars
or a direct `curl -x` probe).

Exit codes:

- `0`: variant ready (and serving, if `--serve`); or restore completed.
- `2`: the target endpoint was not found among the recording's outbound
  pairs (the available endpoints are listed).
- `3`: the variant failed validation: the mock will not load it. A mock that
  dies at startup logging `failed to parse response line` means the edit
  broke the RRPair; nothing is served.
- `4`: precondition or usage failure.

The proof-only hook `CHAOS_FORCE_BAD_EDIT=1` corrupts an edited file with
the documented failure mode so the validation gate can be exercised; never
set it outside the proof.

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
- **flaky**: because the ratio is exact and periodic, retry policies are
  testable exactly, not statistically. With `1/2` and one immediate retry,
  every client call should succeed; a client-visible failure rate equal to
  F/N means no retries at all.
- **slow**: watch for the app's timeout budget. If the injected latency is
  under the app's timeout you should see slow 200s (latency propagated); if
  over, whatever the app does instead (5xx, hang, fallback) is the finding.

## Related

- **proxymock-regression-test**: run it against the app while this skill's
  chaos mock is serving to turn observed resilience behavior into a gate.
- **proxymock-load-test**: drive load at the app while the downstream is
  slow or flaky to see resilience under pressure.
- **proxymock-verify-fix**: after fixing a resilience bug this skill
  exposed, capture the incident and prove the fix by replay.

## Proof

```bash
./skills/proxymock-chaos-mock/scripts/prove-proxymock-chaos-mock.sh
```

The proof is hermetic (no cloud, no live downstream, no app build) and runs
against a copy of the committed recording. It builds and validates a variant
for all five scenarios and verifies the source recording stays untouched;
serves the flaky variant and proves via direct proxy curls that responses
alternate 503/200 in the exact configured 1/2 ratio while an untargeted
endpoint stays healthy; proves `--restore` swaps the healthy recording back
on the same port; measures the slow variant at or above the configured
500ms; and verifies a bogus `--target` exits 2 and a deliberately broken
edit (the documented parse-failure mode, via the proof hook) is caught by
validation with exit 3.
