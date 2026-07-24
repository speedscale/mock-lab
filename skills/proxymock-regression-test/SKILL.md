---
name: proxymock-regression-test
description: Replay a recorded proxymock session against a target and gate on per-RRPair result-match tags and budget flips rather than transport failures, catching status-code and behavior regressions that a clean requests.failed hides. Use when users ask to regression-test a service against recorded traffic, verify a code change did not break replay behavior, or gate CI on a proxymock replay.
argument-hint: --in <recording-dir> --test-against <url> [--baseline <replay-dir>] [--fail-on-regression]
---

# proxymock Regression Test

Turn a recording into a regression gate. `proxymock replay` drives the recorded
requests at the target; this skill then judges the run on the signals that
actually move when behavior changes: the per-RRPair `match` tag and, with a
baseline, budget flips from a Compare report. `requests.failed` is not the
gate: a status-code regression (a 201 that becomes a 200) still completes the
HTTP exchange, so `requests.failed` stays 0 while the pair is tagged
`match=fail` (STATUS CODE MISMATCH). Empirically verified.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the recording directory to replay.
- `--test-against`: the target to hit (e.g. `http://localhost:8080`).
- `--baseline`: a prior known-good replay output directory (the `replayed/`
  dir from an earlier run of this skill). Enables baseline-relative match
  gating, where only NEW failures count, and the budget-flip gate. Without it,
  every `match=fail` counts, including the known moving-ID noise floor, so
  always pass a baseline once you have one.
- `--fail-on-regression`: exit nonzero on findings; without it the script
  reports and exits 0.

Run the bundled script:

```bash
# first run: establish a baseline replay
./skills/proxymock-regression-test/scripts/proxymock-regression-test.sh \
  --in ./proxymock/recording --test-against http://localhost:8080 \
  --work-dir ./regress-base

# after a code change: gate against the known-good replay
./skills/proxymock-regression-test/scripts/proxymock-regression-test.sh \
  --in ./proxymock/recording --test-against http://localhost:8080 \
  --baseline ./regress-base/replayed --fail-on-regression
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-regression-test` with the copied skill directory. The
scripts source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Preconditions the script checks

- **Blueprint anchoring.** Blueprints are loaded only from the `--in` path's
  parent proxymock directory's `blueprints/` subdir, not from cwd and not from
  the output workspace (the same anchoring rule replay applies to `--out`,
  which "anchors to the `--in` workspace, not the current directory"). If that
  dir is missing or empty the script warns loudly: auth and moving-ID
  endpoints will be unreplayable (401s), and a regression on their success
  paths is UNDETECTABLE because they fail before and after the change.
- **Blueprint application.** Do not trust the console line
  `Applied N active blueprint(s)`: it reflects snapshot-scoped state, not the
  workspace. The script verifies by grepping the replay output RRPairs for
  `smart_replace` events and warns when a blueprint exists but none appear.
- **Mock reminder.** When the recording contains outbound pairs, the script
  reminds you that `proxymock mock` requires an explicit `--in`; it does not
  discover the recording from cwd.

## Output contract

Written to `--work-dir` (default a timestamped dir): `replayed/` (the replay
output, your next `--baseline`), `result.json`, `report.json` / `report.html` /
`report.prompt.md` (a Compare report when `--baseline` is set), and
`summary.json` with the verdict (new match failures, budget flips, paths).

Exit codes:

- `0`: no regression, or findings present without `--fail-on-regression`.
- `2`: precondition failure (bad args, missing dirs, replay did not run).
- `3`: match-tag regressions: pairs failing now that passed in the baseline.
- `4`: budget flips: a budget that passed in the baseline now fails, e.g.
  `reliability.match >= 99` starting to fail. Gated on flips, not raw
  regressed-finding counts, because rotating values (order ids) churn security
  findings and inflate counts between otherwise identical runs.

When both fire, the match-tag code (3) wins.

## Body-level diff (MCP step)

The `match` tag catches status-code changes but tolerates body changes, so a
field-level regression needs a response diff between the new `replayed/` dir
and the baseline replay dir. The CLI has no equivalent: `proxymock files
compare` pairs files by `refUuid` reference (recording to replay only; two
replay dirs yield "Total comparisons: 0"). Use the proxymock MCP tool
`response_diff` instead:

- Findings are classed `value_changed` / `field_added` / `field_removed` /
  `type_change`, with regressions ranked first.
- It detects renames as removed+added pairs, catches off-by-ones exactly, and
  classes additive fields as `field_added` (non-breaking).
- It also diffs `http.res.statusCode`; the tool docs understate this.
- Allowlist the deterministic noise floor before judging: `Date` response
  headers, rotating `access_token` / `order_id` values, and their
  `Content-Length` side effects.

## Interpretation

- **New match failure, `requests.failed` 0**: the classic silent regression; a
  status or contract change the transport layer cannot see. Read the
  `NEW FAIL` lines for recorded vs observed status.
- **Failures present but none new**: the known noise floor (moving-ID
  endpoints without an applied blueprint). Fix the blueprint to shrink it, or
  keep gating baseline-relative.
- **Budget flip without match failures**: an aggregate drifted past its
  budget (match percentage, p95, 5xx count) even though no single pair
  regressed; check `report.prompt.md` for which finding moved it.
- **`match=fail` on bodies that look right**: rotating values in the response;
  candidates for the noise allowlist, confirmed with the MCP `response_diff`
  classes above.

## Related

- **proxymock-compare-results**: deep report/drift comparison of the two
  replay dirs this skill produces and consumes.
- **proxymock-load-test**: same replay under parallel virtual users for
  latency and throughput SLOs.
- **proxymock-replay-tuning**: when misses come from the mock set rather than
  the app, tune signatures and transforms until the replay matches.

## Proof

```bash
./skills/proxymock-regression-test/scripts/prove-proxymock-regression-test.sh
```

The proof starts the mock-lab Go app with its downstream mocked from the
committed recording, establishes a baseline replay, verifies a gated rerun
against the unchanged target passes (the noise floor does not false-positive),
then points the same gate at a stub that turns one endpoint's 200 into a 404
and verifies the run exits 3 with `requests.failed` still 0.
