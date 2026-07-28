---
name: proxymock-verify-fix
description: Verify a bug fix by replaying the incident traffic capture against the fixed build, reading match failures of the form "recorded 500 -> observed 200" as the fix signal while treating any other new mismatch, on status or response body, as collateral regression. Use when users ask to verify a bug fix with recorded traffic, prove a production incident no longer reproduces, or turn an incident capture into the fix's regression test.
argument-hint: --in <incident-recording-dir> --test-against <url> [--expect <pattern>] [--baseline <buggy-replay-dir>] [--fail-on-collateral]
---

# proxymock Verify Fix

A bug manifested in production and traffic was captured while it manifested,
so the incident recording contains the FAILING responses (the 500s) as
recorded truth. The developer then fixed the code. This skill proves the fix
by replaying that same capture at the fixed build: the reproduction IS the
test, and no hand-written test is needed. The pass/fail semantics invert
relative to a regression test, because recorded-vs-observed equality is the
match pass criterion: a faithfully reproduced error is a match PASS, and the
fix shows up as a match FAILURE of the form "recorded 500 -> observed 200" on
the incident endpoint. A run where every pair matches means the bug STILL
REPRODUCES (the buggy behavior equals the recording). `requests.failed` sees
none of this: a status change still completes the HTTP exchange, so it stays
0 and the fix appears only in the per-RRPair verdict. Empirically verified.

`proxymock replay --verify-fix [--expect <regex>]` implements that inversion
natively: it prints `FIX CONFIRMED` / `BUG REPRODUCED` / `COLLATERAL`, writes
`<out>/replay-verdict.json` with a `classification` per pair, and exits 0 / 2 /
3 to match this skill's contract. The script delegates the partition and those
exit codes to it and adds the checks replay does not make.

## The verdict scores bodies too (native, default)

`--verify-fix` scores response bodies alongside status codes, so a body-only
collateral regression alongside a real fix is now caught as collateral (exit 3)
instead of passing as `fix-confirmed`. Each pair carries `bodyMatch` and a
`bodyChanges` list of `{severity, kind, endpoint, location, baseline,
candidate}` entries, `kind` being `value_changed` / `field_added` /
`field_removed`. There is no separate body-diff step to run.

**Baseline masking is per-pair, so a `known-mismatch` can be hiding a different
failure.** The classification means "this pair also failed against the buggy
build", not "this pair fails the same way it did". Measured on v2.5.812, the
common shape changes ARE caught (an already-401 pair that starts returning 500
scores `newMismatch: true`, as does a body change at a location the baseline did
not fail at), but a delta the volatile heuristic owns is not counted, and that
heuristic is not stable run to run. This matters more here than in the
regression twin, because the natural `--baseline` for a fix run is a replay
against the BUGGY build, where the incident's neighbors are already failing. The
script compares each masked pair's current `observedStatus` and `bodyChanges`
against the baseline verdict's and prints `ADVISORY: masked but different` when
they diverge; it does not fail the build, so read those lines.

**Volatile suppression is a heuristic, and it is undocumented.** It suppresses
by field, not by value: measured on v2.5.812, an `order_id` change is ignored
whatever the new value looks like, and so is the ISO-8601 `created` timestamp,
while `status` / `project` / `total` changes on the same pairs are scored. Round
2 of experiment 08 measured the opposite for a live `order-<16hex>`. So a
body-clean run is not guaranteed on a recording whose app mints fresh values,
and the collateral list is only as trustworthy as the baseline you gate it
against. See proxymock-regression-test for the full measurement.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the incident recording directory (captured while the bug
  manifested).
- `--test-against`: the build to verify (e.g. `http://localhost:8080`).
- `--expect`: a regex matched against the request URI naming the incident
  endpoint(s). Without it the incident set is auto-detected: every pair whose
  RECORDED response has an error status (>= 400). With it, a recorded-error
  pair outside the pattern that changes behavior counts as collateral, since
  you asserted which endpoints should change.
- `--baseline`: a replay output dir from a run against the BUGGY build (e.g.
  `run-1/replayed` from a `--reproduce` run). Non-incident mismatches already
  present there are environment noise, not collateral.
- `--fail-on-collateral`: escalate baseline-known non-incident mismatches to
  fatal as well. NEW collateral is always fatal.
- `--mocks`: a healthy recording dir to union with the incident capture when
  mocking the target's downstream (see preconditions below).
- `--reproduce` / `--runs N`: run BEFORE fixing; replays the capture N times
  (default 3) against the buggy build and asserts the incident endpoints
  return the recorded error with identical match outcomes every run,
  confirming the capture is a deterministic reproduction. No native
  equivalent: `-n/--times` replays repeatedly but never compares the runs, so
  the per-run stability check stays here.

Run the bundled script:

```bash
# before fixing: confirm the capture reproduces the bug deterministically
./skills/proxymock-verify-fix/scripts/proxymock-verify-fix.sh \
  --in ./incident/recording --test-against http://localhost:8080 \
  --reproduce --work-dir ./reproduce-work

# after fixing: prove the fix with the same capture
./skills/proxymock-verify-fix/scripts/proxymock-verify-fix.sh \
  --in ./incident/recording --test-against http://localhost:8080 \
  --expect '^/api/stats' --baseline ./reproduce-work/run-1/replayed
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-verify-fix` with the copied skill directory. The scripts
source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Preconditions the script checks

- **Blueprint anchoring.** Blueprints load from INSIDE the `--in` tree (replay
  reads `--in` recursively), not from cwd and not from a sibling of `--in`; a
  `blueprints/` dir parked beside the recording is silently inert, and the
  script says so when it finds one. It warns when no blueprint is loadable, and
  warns again when a blueprint exists but no `smart_replace` events appear in
  the replay output, since loading a blueprint is not running it. Unapplied
  blueprints make moving-ID endpoints fail for reasons unrelated to the fix and
  pollute the collateral list. Replay's own `--require-blueprint` is accurate on
  v2.5.814 — re-measured with controls, it exits 1 both for a name that never
  loaded and for one that loaded without firing, the latter agreeing with the
  grep — but it is not used as the gate: it aborts the replay before
  `<out>/replay-verdict.json` is written, and that verdict is what classifies
  the fix, so gating on it would cost the whole verification.
- **The incident capture's downstream gap.** An incident capture
  systematically LACKS the fixed code path's downstream traffic: the buggy
  handler usually errored BEFORE calling its dependencies, so no outbound
  pair for that call was ever recorded. When the fixed build's downstream is
  mocked from the incident capture alone, the new downstream call has no
  mock: it is passed through to the live dependency (needs network) or
  returns 502 when air-gapped, and either can masquerade as "fix not
  confirmed" or collateral. Supply `--mocks <healthy recording dir>` and the
  script prints the union mock command. `proxymock mock` accepts repeated
  `--in` flags and serves mocks from all of them (empirically verified with
  a split recording; no combined temp dir is needed):

  ```bash
  proxymock mock --in ./incident/recording --in ./healthy/recording -- <your app>
  ```

## Output contract

Written to `--work-dir` (default a timestamped dir): `replayed/` (or
`run-N/replayed/` in `--reproduce` mode) including proxymock's own
`replay-verdict.json`, `result.json` per replay (metrics: the verdict file
carries none), and `summary.json` with the machine-readable verdict: `fixed`,
`reproduced`, and `collateral` lists, each entry carrying recorded and observed
statuses plus the source and replay RRPair file paths. The terse human summary
prints absolute paths.

`summary.json` keys are unchanged, but `unreplayedIncident` is now always
empty: the native verdict scores only pairs that were actually replayed, so an
incident pair with no replay outcome is not reported. A nonzero
`requests.failed` is the signal that one went missing, and the script warns on
it. Every `fixed` / `reproduced` / `collateral` entry additionally carries
`bodyMatch` and its `bodyChanges`.

Exit codes:

- `0`: fix confirmed AND no collateral (every incident endpoint flipped from
  its recorded error to a success status). In `--reproduce` mode: the
  incident reproduces deterministically.
- `2`: fix NOT confirmed: the incident endpoints still reproduce the recorded
  error. A plain "all pairs match" run lands here with the message "bug
  reproduces; fix not present". In `--reproduce` mode: the capture did not
  reproduce the incident, or match outcomes differed between runs.
- `3`: collateral regression detected (with or without the fix): a pair whose
  recording succeeded now observes something different.
- `4`: precondition failure (bad args, missing dirs, no recorded-error pairs
  to verify, replay did not run). Native `--verify-fix` exits 1 with
  "no recorded-error (>=400) pairs to verify" or "no recorded-error (>=400)
  pairs match --expect"; the script maps that onto 4, since replay has no
  distinct precondition code.

## Interpretation

- **`FIX CONFIRMED` lines, exit 0**: each incident endpoint's mismatch is the
  fix signal: recorded error, observed success, and no neighbor changed its
  status or its body. Save the `--reproduce` replay dir and this run's
  `replayed/` dir; together they document before and after.
- **"bug reproduces; fix not present" (exit 2)**: the replay matched the
  recording, including the errors. The fix is not in the build under test
  (wrong binary, stale deploy, or the fix does not cover the recorded case).
- **`BUG REPRODUCED` with a different error (exit 2)**: recorded 500, observed
  404 or similar. The behavior changed but did not become a success; the bug
  morphed rather than fixed.
- **`COLLATERAL` lines (exit 3)**: a recorded-success pair now returns a
  different status or a different body. The fix broke a neighbor; the summary
  still reports any fix signal seen alongside, and each body finding prints as
  a `BODY <severity>` line. With `--baseline`, a mismatch that also failed
  against the buggy build is classified `known-mismatch` (environment noise,
  printed as `known noise`) and does not fail the run unless
  `--fail-on-collateral` is set.
- **`ADVISORY: masked but different`**: one of those `known noise` pairs is not
  failing the way it failed against the buggy build. Read it by hand; the
  classification will not.
- **`requests.failed` above 0**: an incident pair may never have replayed.
  The verdict scores only what it replayed, so check the replay log and the
  downstream-gap warning before concluding anything about the fix.

## Related

- **proxymock-regression-test**: the non-inverted twin. Use it with a healthy
  recording to prove a change broke nothing; use this skill with an incident
  recording to prove a change fixed the bug. The two share the replay-verdict
  mechanics and the blueprint preconditions.
- **proxymock-compare-results**: deep report and drift comparison between the
  buggy-baseline replay dir and this skill's `replayed/` output when you need
  more than the status partition.

## Proof

```bash
./skills/proxymock-verify-fix/scripts/prove-proxymock-verify-fix.sh
```

The proof is hermetic (no cloud, no live downstream, no app build). It
fabricates an incident recording by flipping one GET pair's recorded status to
500 in a copy of the committed recording, then drives the verify script through
five sub-cases against local stubs that replay the recording's own statuses and
bodies, so each seeded change is the only difference: `--reproduce` against a
buggy stub exits 0 (deterministic reproduction), verify against a fixed stub
exits 0 with the recorded-500-to-observed-200 flip reported and
`requests.failed` still 0, verify against the buggy stub exits 2 with "bug
reproduces; fix not present", verify against a stub with a second unrelated
status discrepancy exits 3 with the collateral pair identified, and verify
against a stub whose only collateral is a CHANGED FIELD on an unchanged 200
also exits 3 -- the case that scored `fix-confirmed` before body scoring.
