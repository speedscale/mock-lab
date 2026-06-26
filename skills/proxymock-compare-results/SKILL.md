---
name: proxymock-compare-results
description: Generate a deep proxymock report over recorded or replayed RRPairs and, with a baseline, a before/after Compare report showing what regressed, improved, or persisted across performance, reliability, and security. Writes JSON, HTML, and an LLM digest. Use when users ask to compare two replay/recording results, diff before vs after a change, find regressions, or analyze a recording's quality.
argument-hint: --in <dir> [--baseline <dir>] [--drift] [--fail-on-regression]
---

# proxymock Deep Result Comparison

`proxymock report` analyzes a set of RRPairs across three pillars —
Performance, Reliability, Security — and writes report files. Give it a
`--baseline` and it becomes a **Compare report**: regressed / improved /
persistent findings between two runs, built for an iterate-and-verify loop
(record → change code → replay → compare).

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the **current** RRPair directory — usually a fresh replay output
  (`proxymock/results/replayed-*`) or a recording.
- `--baseline`: the **prior** RRPair directory to compare against. Omit for a
  single-run report.
- `--drift`: also run `proxymock drift` to list fields whose values vary
  between the two sets (each carries a prefilled transform you can drop into a
  responder signature or generator).
- `--fail-on-regression`: exit nonzero if the Compare report lists any
  regression — use as a CI gate.

Run the bundled script:

```bash
# single report over one recording
./skills/proxymock-compare-results/scripts/proxymock-compare-results.sh \
  --in ./proxymock/recording

# before/after: did anything regress between two replay runs?
./skills/proxymock-compare-results/scripts/proxymock-compare-results.sh \
  --in  ./proxymock/results/replayed-after \
  --baseline ./proxymock/results/replayed-before \
  --drift --fail-on-regression
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-compare-results` with the copied skill directory.

## Output files

Written to `--out-dir` (default a timestamped dir):

- `report.json` — machine-readable (`scope`, `scores`, `budgets`,
  `performance`, `reliability`, `security`; deltas when comparing).
- `report.html` — self-contained, open in a browser to skim findings.
- `report.prompt.md` — ~2-4 KB LLM-pasteable digest. **Read this first.** In
  compare mode it has three sections: *What regressed*, *What improved*,
  *Still present (high severity, survived both runs)*.
- `drift.json` — only with `--drift`; the DriftReport.

The script prints the regressed / improved / persisted counts parsed from the
digest, and the absolute paths.

## A typical before/after loop

1. Replay the current code, save the output (e.g. `replayed-before/`).
2. Make the change.
3. Replay again into `replayed-after/`.
4. Compare: `--in replayed-after --baseline replayed-before`.
5. Read `report.prompt.md`. Treat *What regressed* as the blast radius of the
   change; *What improved* as what the change fixed (and what's now
   load-bearing); *Still present* as the next priorities.

## Interpretation

- **A regression that tracks a changed input, not code** — IDs/tokens/dates
  that differ between runs can surface as a finding. The digest flags this as a
  confound; confirm with `--drift` (drifting value) before blaming code.
- **Score deltas** — `performance`, `reliability`, `security` scores move with
  the findings; a flat score with new findings usually means a low-severity
  swap, not a real regression.
- **Drift recommendations** — fields in `drift.json` that *should* be stable
  point at a real bug; fields that are *expected* to vary (a fresh token) are
  candidates to wildcard-ignore in the responder signature.

When reporting results, lead with the regressed/improved counts and the path to
`report.prompt.md` and `report.html`.

## Related

- **proxymock-load-test** — generate the before/after replay outputs this skill
  compares.
- **proxymock-replay-tuning** — when the comparison shows match-rate misses,
  tune the mock set until the same replay passes.

## Proof

```bash
./skills/proxymock-compare-results/scripts/prove-proxymock-compare-results.sh
```

The proof builds a degraded baseline from the committed recording, runs the
compare, and verifies the report files are written and that the Compare report
detects the seeded regression (and reports none when current == baseline).
