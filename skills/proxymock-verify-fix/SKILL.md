---
name: proxymock-verify-fix
description: Verify a bug fix by replaying the incident traffic capture against the fixed build, reading match failures of the form "recorded 500 -> observed 200" as the fix signal while treating any other new mismatch as collateral regression. Use when users ask to verify a bug fix with recorded traffic, prove a production incident no longer reproduces, or turn an incident capture into the fix's regression test.
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
0 and the fix appears only in the per-RRPair match tags of the replayed
RRPairs. Empirically verified.

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
  confirming the capture is a deterministic reproduction.

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

- **Blueprint anchoring.** Blueprints load only from the `--in` path's parent
  proxymock directory's `blueprints/` subdir, not from cwd and not from the
  output workspace. The script warns when that dir is missing or empty, and
  warns again when a blueprint exists but no `smart_replace` events appear in
  the replay output (the console line `Applied N active blueprint(s)` is
  snapshot-scoped and not trustworthy). Unapplied blueprints make moving-ID
  endpoints fail for reasons unrelated to the fix and pollute the collateral
  list.
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
`run-N/replayed/` in `--reproduce` mode), `result.json` per replay, and
`summary.json` with the machine-readable verdict: `fixed`, `reproduced`, and
`collateral` lists, each entry carrying recorded and observed statuses plus
the source and replay RRPair file paths. The terse human summary prints
absolute paths.

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
  to verify, replay did not run).

## Interpretation

- **FIXED lines, exit 0**: each incident endpoint's match failure is the fix
  signal: recorded error, observed success. Save the `--reproduce` replay dir
  and this run's `replayed/` dir; together they document before and after.
- **"bug reproduces; fix not present" (exit 2)**: the replay matched the
  recording, including the errors. The fix is not in the build under test
  (wrong binary, stale deploy, or the fix does not cover the recorded case).
- **REPRODUCED with a different error (exit 2)**: recorded 500, observed 404
  or similar. The behavior changed but did not become a success; the bug
  morphed rather than fixed.
- **COLLATERAL lines (exit 3)**: a recorded-success pair now returns
  something different. The fix broke a neighbor; the summary still reports
  any fix signal seen alongside.
- **UNREPLAYED incident pairs (exit 2)**: the incident endpoint produced no
  replay outcome at all; check the replay log and the downstream-gap warning
  before concluding anything about the fix.
- **Body-level confidence**: match tags catch status changes but tolerate
  body changes. When the fix should alter response bodies, diff this run's
  `replayed/` dir against the buggy baseline with the proxymock MCP
  `response_diff` tool (see proxymock-regression-test for the noise
  allowlist).

## Related

- **proxymock-regression-test**: the non-inverted twin. Use it with a healthy
  recording to prove a change broke nothing; use this skill with an incident
  recording to prove a change fixed the bug. The two share match-tag
  mechanics and the blueprint preconditions.
- **proxymock-compare-results**: deep report and drift comparison between the
  buggy-baseline replay dir and this skill's `replayed/` output when you need
  more than the status partition.

## Proof

```bash
./skills/proxymock-verify-fix/scripts/prove-proxymock-verify-fix.sh
```

The proof is hermetic (no cloud, no live downstream, no app build). It
fabricates an incident recording by flipping one GET pair's recorded status
to 500 in a copy of the committed recording, then drives the verify script
through four sub-cases against local stubs: `--reproduce` against a buggy
stub exits 0 (deterministic reproduction), verify against a fixed stub exits
0 with the recorded-500-to-observed-200 flip reported and `requests.failed`
still 0, verify against the buggy stub exits 2 with "bug reproduces; fix not
present", and verify against a stub with a second unrelated discrepancy
exits 3 with the collateral pair identified.
