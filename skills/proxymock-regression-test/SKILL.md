---
name: proxymock-regression-test
description: Replay a recorded proxymock session against a target and gate on the per-RRPair replay verdict (response status AND body) plus budget flips rather than transport failures, catching status-code, field-level and behavior regressions that a clean requests.failed hides. Use when users ask to regression-test a service against recorded traffic, verify a code change did not break replay behavior, or gate CI on a proxymock replay.
argument-hint: --in <recording-dir> --test-against <url> [--baseline <replay-dir>] [--fail-on-regression]
---

# proxymock Regression Test

Turn a recording into a regression gate. `proxymock replay --baseline
<prior replay dir> --fail-on-new-mismatch` drives the recorded requests at the
target and gates on new mismatches natively (exit 3); this skill wraps that
with the preconditions it does not check and adds the budget-flip gate.
`requests.failed` is not the gate: a status-code regression (a 201 that becomes
a 200), or a changed field behind an unchanged 200, still completes the HTTP
exchange, so `requests.failed` stays 0 while the pair is scored a mismatch.
Empirically verified.

## The verdict scores bodies too (native, default)

`replay-verdict.json` scores response bodies alongside status codes. Measured
on v2.5.812: `/api/stats` returning `total: 25` where the recording says `24`,
with an unchanged 200, scores `match: pass` but `bodyMatch: fail` with
`{severity: regression, kind: value_changed, location:
http.res.bodyBase64.total, baseline: "24", candidate: "25"}` and trips the gate
(exit 3, verdict `new-mismatch`). `kind` is one of `value_changed`,
`field_added`, `field_removed`; the summary adds `bodyMismatches`. To score
status only, replay takes `--ignore-body-changes` (this skill does not).

Two measured caveats decide how you use it:

**Baseline masking is per-pair, so a known-mismatch can be hiding a different
failure.** `known-mismatch` / `newMismatch: false` means "this pair also failed
in the baseline", not "this pair fails the same way it did". Measured on
v2.5.812, the common shape changes ARE caught: an already-401 pair that starts
returning 500 scores `newMismatch: true`, and so does a pair that picks up a
body change at a location the baseline did not fail at. What is not counted is a
delta the volatile heuristic owns -- and that heuristic is not stable: the same
`order_id` value change was scored a `value_changed` regression in one run and
suppressed entirely in another. So do not read `known-mismatch` as "nothing
changed here". The script compares each masked pair's current `observedStatus`
and `bodyChanges` against the baseline verdict's and prints `ADVISORY: masked
but different` when they diverge; it does not fail the build, so read those
lines.

**Volatile suppression is a heuristic, and it is undocumented.** It decides
which churn is noise, by field rather than by value. Measured on v2.5.812
against the committed recording: `Date` headers, bare 64-hex tokens, the
`order_id` field (suppressed whatever the replacement value looks like -- hex,
non-hex, shorter, even renaming the field) and the ISO-8601 `created` timestamp
are all suppressed, while `status`, `project`, `total` and `expires_in` changes
on the same pairs are scored. Round 2 of experiment 08 measured the opposite
for a live `order-<16hex>`, so do not assume any particular rotating value is
covered. Treat a raw `bodyMismatches: 0` as luck: establish a `--baseline` and
gate on NEW mismatches, which is what keeps the gate green on a recording whose
app mints fresh values every run.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the recording directory to replay.
- `--test-against`: the target to hit (e.g. `http://localhost:8080`).
- `--baseline`: a prior known-good replay output directory (the `replayed/`
  dir from an earlier run of this skill). Passed straight to `replay
  --baseline`, which gates baseline-relative so only NEW mismatches count, and
  enables the budget-flip gate. Without it, every mismatch counts, including
  the known moving-ID noise floor, so always pass a baseline once you have one.
  (`--fail-on-new-mismatch` is rejected by replay without `--baseline`, so the
  no-baseline gate is applied by the script over the same verdict file.)
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

- **Blueprint anchoring.** Blueprints load from INSIDE the `--in` tree: replay
  reads `--in` recursively, so it finds `<--in>/blueprints/`, and a workspace
  root passed as `--in` picks up its own `blueprints/` beside `recording/`. A
  `blueprints/` dir that is a SIBLING of `--in` is never read, which is the
  usual misplacement; the script names that case explicitly when it sees it.
  If no blueprint is loadable the script warns loudly: auth and moving-ID
  endpoints will be unreplayable (401s), and a regression on their success
  paths is UNDETECTABLE because they fail before and after the change.
- **Blueprint application.** Loading a blueprint is not running it, and the
  `Loaded blueprint ...` console lines only report loading. The script verifies
  application by grepping the replay output RRPairs for `smart_replace` events
  and warns when a blueprint exists but none appear. Replay's own
  `--require-blueprint` is accurate on v2.5.814 — re-measured with controls, it
  exits 1 both for a name that never loaded ("was not loaded from the `--in`
  workspace") and for one that loaded without firing ("loaded but none of its
  transform chains ran"), the latter agreeing with the grep. It is still not
  the gate, because it aborts the replay BEFORE `<out>/replay-verdict.json` is
  written, and that verdict is the entire regression signal. Gating on it would
  trade a blueprint warning for the loss of every status and body comparison in
  the run, so the script warns and still measures.
- **Mock reminder.** When the recording contains outbound pairs, the script
  reminds you that `proxymock mock` requires an explicit `--in`; it does not
  discover the recording from cwd.

## Output contract

Written to `--work-dir` (default a timestamped dir): `replayed/` (the replay
output, your next `--baseline`, containing proxymock's own
`replay-verdict.json`), `result.json` (metrics: the verdict file carries none),
`report.json` / `report.html` / `report.prompt.md` (a Compare report when
`--baseline` is set), and `summary.json` with the verdict (new mismatches,
budget flips, paths) read from `replay-verdict.json`.

`summary.json` keys are unchanged, with one sharpened meaning:
`match.baselineFailures` now counts THIS run's mismatches that were already
failing in the baseline, not the baseline's total failure count. Two additions
carry the body verdict: `match.bodyFailures` (the summary's `bodyMismatches`)
and a `bodyMatch` plus `bodyChanges` on every `newFailures` entry.

Exit codes:

- `0`: no regression, or findings present without `--fail-on-regression`.
- `2`: precondition failure (bad args, missing dirs, replay did not run).
- `3`: regressions: pairs mismatching now, on status or body, that passed in
  the baseline. Delegated to `replay --fail-on-new-mismatch`, which exits 3
  itself.
- `4`: budget flips: a budget that passed in the baseline now fails, e.g.
  `reliability.match >= 99` starting to fail. Gated on flips, not raw
  regressed-finding counts, because rotating values (order ids) churn security
  findings and inflate counts between otherwise identical runs.

When both fire, the status-level code (3) wins.

## Interpretation

- **`NEW MISMATCH` line, `requests.failed` 0**: the classic silent regression;
  a status or contract change the transport layer cannot see. replay prints
  it as `NEW MISMATCH: POST /api/orders recorded 201 -> observed 200`, and
  body-only findings as `... status 200, body total removed (was 24)`.
- **Verdict `pass`, exit 0**: status and body both matched. This is now a real
  clean bill of health, not a status-only one.
- **`match: pass` with `bodyMatch: fail`**: the status is right and a field is
  not. The script prints each `bodyChanges` entry as a `BODY <severity>` line.
- **Failures present but none new**: the known noise floor (moving-ID endpoints
  without an applied blueprint, and the recording's own rotating ids). Fix the
  blueprint to shrink it, or keep gating baseline-relative.
- **`ADVISORY: masked but different`**: a pair the gate is masking is failing
  differently than it did in the baseline. The gate cannot see this; read the
  pair by hand.
- **Budget flip without match failures**: an aggregate drifted past its
  budget (match percentage, p95, 5xx count) even though no single pair
  regressed; check `report.prompt.md` for which finding moved it.

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
committed recording, establishes a baseline replay, and verifies a gated rerun
against the unchanged target passes (the noise floor does not false-positive).
It then points the same gate at stubs that replay the recording's own statuses
and bodies with one seeded change each: turning an endpoint's 200 into a 404
exits 3 with `requests.failed` still 0; changing only `/api/stats` `total` from
24 to 25 also exits 3, with the status identical to the recording and a
`value_changed` on `total` in the summary (the case that scored `pass` before
body scoring); and making a baseline-failing pair fail DIFFERENTLY keeps the
gate green while printing the masked-but-different advisory.
