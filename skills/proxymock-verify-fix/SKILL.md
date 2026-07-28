---
name: proxymock-verify-fix
description: Verify a bug fix by replaying the incident traffic capture against the fixed build with proxymock replay --verify-fix, reading recorded-error to observed-success as the fix signal while any other new mismatch, on status or body, is collateral. Use when users ask to verify a bug fix with recorded traffic, prove a production incident no longer reproduces, or turn an incident capture into the fix's regression test.
argument-hint: --in <incident-recording-dir> --test-against <url> [--expect <regex>]
---

# proxymock Verify Fix

A bug manifested in production and traffic was captured while it manifested, so
the incident recording holds the FAILING responses as recorded truth. Replay
that capture at the fixed build and the reproduction IS the test — no
hand-written test needed. One native command:

```bash
proxymock replay \
  --in ./incident/recording \
  --test-against http://localhost:8080 \
  --verify-fix --expect '^/api/stats'
```

**Requires proxymock v2.5.814 or newer.**

## The semantics invert. Read this before reading any output.

Match compares **observed against recorded**, so a faithfully reproduced error
is a match **PASS**. That flips everything:

- An **all-match run means the bug STILL REPRODUCES**. Green is bad here.
- The **fix appears as a mismatch**: `recorded 500 -> observed 200`.
- `requests.failed` sees none of it. A status change still completes the HTTP
  exchange, so it stays 0 and the fix shows up only in the per-pair verdict.

`--verify-fix` implements that inversion natively: it prints `FIX CONFIRMED` /
`BUG REPRODUCED` / `COLLATERAL`, writes a `classification` per pair into
`<out>/replay-verdict.json`, and exits accordingly. Empirically verified.

## Works with your stack (no bash required)

```bash
# before the fix: confirm the capture reproduces the bug
proxymock replay --in ./incident/recording --test-against http://localhost:8080 \
  --out ./reproduce --verify-fix --expect '^/api/stats'   # expect exit 2

# after the fix: prove it
proxymock replay --in ./incident/recording --test-against http://localhost:8080 \
  --out ./verify --verify-fix --expect '^/api/stats' --baseline ./reproduce
```

| Exit | Verdict | Meaning |
| --- | --- | --- |
| `0` | `fix-confirmed` | every selected incident pair flipped recorded-error -> observed-success, with no collateral |
| `2` | `bug-still-reproduces` | the incident pairs still return the recorded error |
| `3` | collateral | a pair whose recording succeeded now differs, on status or body |
| `1` | — | precondition failure, e.g. no recorded-error (>= 400) pairs matched `--expect` |

That table is the whole integration surface. Any CI system, in any language,
can shell out to this one line; the repo's `quality-loop.sh verify-fix` is
optional convenience that builds it and passes the exit code through.

`--expect` is a regex over the request URI naming the incident endpoint(s).
Without it the incident set is auto-detected as every pair whose **recorded**
response was >= 400. With it, a recorded-error pair outside the pattern that
changes behavior counts as collateral — you asserted which endpoints should
change.

## Incident captures have a downstream hole

An incident capture systematically **lacks the fixed code path's downstream
traffic**: the buggy handler usually errored *before* calling its dependency,
so no outbound pair for that call was ever recorded. Mock the fixed build's
downstream from the incident capture alone and the new call has no mock — it is
passed through to the live dependency (needs network) or 502s when air-gapped,
and either can masquerade as "fix not confirmed" or as collateral.

Union the incident capture with a healthy recording. `proxymock mock` takes
repeated `--in` and serves from all of them, and it **requires an explicit
`--in`** — it does not discover a recording from cwd:

```bash
proxymock mock --in ./incident/recording --in ./healthy/recording -- <your app>
```

If you cannot union, declare the network dependency out loud rather than
letting a passthrough silently decide the verdict.

## Body scoring and baseline masking

`--verify-fix` scores response **bodies** alongside statuses by default, so a
body-only collateral regression alongside a real fix is caught as collateral
(exit 3) rather than passing as `fix-confirmed`. Each pair carries `bodyMatch`
and `bodyChanges[]` of `{severity, kind, endpoint, location, baseline,
candidate}`. `--ignore-body-changes` restores status-only scoring.

The natural `--baseline` for a fix run is a replay against the **buggy** build,
where the incident's neighbors are often already failing. Masking compares
change sets: a pair exempt for the failure it showed against the buggy build is
**not** exempt when it starts failing differently (verified — an identical
failure stays masked at exit 0, a different failure on the same pair is caught
as a new mismatch at exit 3). What masking cannot catch is a delta the volatile
field-name heuristic owns, and that heuristic is undocumented and observed
unstable, so gate against a baseline rather than against a raw zero. See
proxymock-regression-test for the full measurement.

## Blueprints

Same rules as the regression skill, and they matter more here because an
unapplied blueprint pollutes the collateral list with failures unrelated to the
fix. In short: blueprints load from the workspace `proxymock/blueprints/` dir
(the parent of the recording) and from a `blueprints/` copy inside `--in`;
workspace discovery is not reproducible across identical recordings under
different names, so if it does not load, put a copy inside `--in`. Confirm with
the `Loaded blueprint` line. A blueprint that filters on `network_address` goes
inert whenever `--test-against` spells the target differently, because replay
rewrites the address to the target — `localhost:8080` fires the chains,
`127.0.0.1:8080` loads the blueprint and fires zero, with no warning.
`--require-blueprint` works on v2.5.814 but writes no verdict file on failure,
which here would cost the entire fix classification; keep it opt-in.

## Interpretation

- **`FIX CONFIRMED`, exit 0**: recorded error, observed success, and no
  neighbor changed status or body. Keep both replay dirs; together they
  document before and after.
- **`BUG REPRODUCED`, exit 2**: the replay matched the recording, errors
  included. The fix is not in the build under test — wrong binary, stale
  deploy, or the fix does not cover the recorded case.
- **`BUG REPRODUCED` with a *different* error**: recorded 500, observed 404.
  The behavior changed but did not become a success; the bug morphed.
- **`COLLATERAL`, exit 3**: the fix broke a neighbor. Body findings print with
  their severity; check them before shipping.
- **`requests.failed` above 0**: an incident pair may never have replayed. The
  verdict scores only what it replayed, so check the log and the downstream
  hole above before concluding anything about the fix.

## Related

- **proxymock-regression-test**: the non-inverted twin, over a healthy
  recording. Same verdict mechanics, same blueprint rules.
- **proxymock-compare-results**: deep comparison of the buggy-baseline replay
  dir against this run's output.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

One shared proof covers this pack (a documented deviation from the repo's
one-prove-per-skill convention: every skill runs the same native binary now).
The cases covering this skill fabricate an incident recording by flipping one
GET pair's recorded status to 500 in a copy of the committed recording, then
verify that `--verify-fix` against a stub serving the *original* 200 exits 0
with `FIX CONFIRMED: recorded 500 -> observed 200`, and against a stub serving
the incident's own 500 exits 2 with `BUG REPRODUCED` — the inversion, both
directions.
