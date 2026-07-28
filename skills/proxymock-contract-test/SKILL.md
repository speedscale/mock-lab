---
name: proxymock-contract-test
description: Contract-test with traffic plus an OpenAPI spec, in two directions. Mode mock-from-spec wraps proxymock generate so a consumer can mock a dependency straight from its spec before any recording exists; mode conformance wraps proxymock validate to check recorded or replayed RRPair response bodies against the spec, reporting exact JSON-path violations. Use when users ask whether a dependency's behavior matches its spec, to validate recorded traffic against an OpenAPI contract, or to mock an API from its spec alone.
argument-hint: <mock-from-spec|conformance> --spec <openapi.(json|yaml)> [--in <rrpair-dir>] [--paths <regex>] [--fail-on-undocumented] [--include-optional] [--serve]
---

# proxymock Contract Test

Tier 1 contract testing from the assets the quality loop already has: an
OpenAPI 3.0+ spec and RRPair traffic. Two modes, one per direction of the
contract:

- **mock-from-spec**: the spec becomes the mock. `proxymock generate` turns
  the spec into RRPairs and `proxymock mock --in <generated>` serves them, so
  a consumer can develop against a dependency's contract before any
  recording exists.
- **conformance**: the traffic is judged by the spec. `proxymock validate`
  checks recorded (or replayed) RRPair response bodies against the spec's
  schemas and reports violations with exact JSON-path attribution.

Conformance is native: `proxymock validate --spec <openapi.(json|yaml|yml)>
--in <rrpair-dir>` does the type, required, enum, and undocumented-field
checks with `$ref` resolution and path-template route matching, and it parses
YAML itself (no PyYAML or `ruby -ryaml` dependency). The skill script is a
thin wrapper that adds `--paths` filtering, the undocumented-fields policy,
and `summary.json`; it does not do any schema checking of its own.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## The asymmetry (read this first)

Conformance mode validates traffic against the DEPENDENCY's spec: the spec
describes the API your app calls, and the recording's outbound pairs are
the evidence. If the app under test has no spec of its own, its inbound API
has no contract document to check against; **its contract is the
recording**. For that side of the boundary, gate behavior with
**proxymock-regression-test** (replay the recording at the app and diff),
not this skill. Contract testing via this loop is one-sided until a spec
for the app exists or is derived from traffic. Pairs whose route is missing
from the spec are reported as `NO_ROUTE` with exit 3, which is how this
asymmetry shows up in practice.

## Inputs

Mode is the first positional argument (or `--mode`).

Shared:

- `--spec`: the OpenAPI 3.0+ spec, `.json`, `.yaml`, or `.yml`.
- `--work-dir`: output directory (default: timestamped dir).

`mock-from-spec` (flags mirror `proxymock generate`):

- `--out`: where generated RRPairs go (default `WORK_DIR/generated`).
- `--direction`: `outbound` (default; mocks for `proxymock mock`),
  `inbound` (tests for `proxymock replay`), or `both`.
- `--host` / `--port`: override the spec's server host/port.
- `--include-optional`: include optional properties. Recommended: default
  bodies are required-only and very sparse.
- `--examples-only`: only responses with explicit examples.
- `--include-paths` / `--exclude-paths`: comma-separated path patterns.
- `--serve`: start the mock on the generated RRPairs after generating.

`conformance`:

- `--in`: the RRPair directory to check, passed to `proxymock validate --in`.
  Point it at the recording's dependency host subdir (e.g.
  `recording/demo-api.trafficreplay.com`), a whole recording, or a replay
  output dir.
- `--paths`: regex; only pairs whose request path matches are reported.
  Scope this to the routes the spec covers when the directory mixes hosts.
  `validate` has no such flag, so this is applied as a filter over its
  output: the counts and the exit code describe the kept pairs.
- `--fail-on-undocumented`: response fields absent from the spec's
  `properties` become violations instead of notes. **Native `validate`
  always treats them as violations**; without this flag the wrapper
  downgrades those findings to notes, which keeps additive response fields
  non-breaking. Nothing else in the verdict is rewritten.

Run the bundled script:

```bash
# does the dependency's recorded behavior match its spec?
./skills/proxymock-contract-test/scripts/proxymock-contract-test.sh conformance \
  --spec lab/openapi.yaml --in lab/proxymock/recording/demo-api.trafficreplay.com

# mock the dependency straight from the spec, before any recording exists
./skills/proxymock-contract-test/scripts/proxymock-contract-test.sh mock-from-spec \
  --spec lab/openapi.yaml --include-optional --serve
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-contract-test` with the copied skill directory. The
scripts source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Measured limits of generated mocks

`proxymock generate` output is **smoke/plumbing tier**: good for developing
against a dependency before any recording exists, proving wiring, and
exercising client code paths. It is not logic-grade data. All measured:

- **Required-only bodies by default.** Optional properties are omitted;
  pass `--include-optional` for fuller payloads.
- **Arrays are 2 identical stub items.** An app aggregating over them sees
  degenerate distributions.
- **Example-less fields get the literal `"example_value"`.** Enum fields are
  the exception: they now get a real member of their enum, so generated
  bodies pass `proxymock validate` against the spec they came from. Add
  `example:` values where a plausible string matters.
- **One response per status.** No response variety within a status code.
- **Path params become match-any templates** (`${{param:id}}` matches any
  concrete id), including params the spec constrains with an enum.

## Output contract

Written to `--work-dir`:

- `conformance`: `summary.json` (per-pair verdicts, violation strings,
  counts, exit code) and `validate.out` (raw `proxymock validate` output);
  per-pair verdict lines on stdout, violations with exact JSON path, field,
  expected type, and actual value, e.g.
  `$[0].stars: type mismatch, expected integer, got string ("many")`.
- `mock-from-spec`: the generated RRPairs (`generated/` unless `--out`),
  `generate.log`, `summary.json` (pair count, mock command), and with
  `--serve`: `serve.json` (pid, ports) and `mock.log`.

Exit codes:

- `0`: mock-from-spec succeeded (and, with `--serve`, the mock loaded);
  conformance found every checked pair conformant.
- `2`: conformance violations found.
- `3`: no violations, but the spec has no route for at least one checked
  pair (partial coverage; each `NO_ROUTE` pair is named).
- `4`: precondition/usage error (bad args, unreadable spec, no pairs left
  after `--paths`, generate produced nothing, `--serve` mock failed to
  load). `proxymock validate`'s own precondition failures (exit 1: missing
  spec or directory, no HTTP pairs) surface as 4 too.

Those are the wrapper's codes, and `validate` already uses the same 0/2/3
scheme, so an unfiltered run passes its verdict straight through. The
wrapper cross-checks that on every run and fails with 4 if its reading of
`validate`'s output disagrees with `validate`'s own exit code.

When violations and route gaps both occur, violations win the exit code
(2); the `NO_ROUTE` pairs are still listed and counted in `summary.json`.

## Interpretation

- **VIOLATION on recorded traffic**: the dependency drifted from its spec,
  or the spec is stale. The recording is evidence of real behavior, so
  treat this as "spec and reality disagree" and decide which one is wrong;
  the JSON path names the exact field.
- **VIOLATION on replayed traffic**: same check, but the responses came
  from your mock or your app under test; a violation introduced between
  recording and replay is a change your code made.
- **NO_ROUTE (exit 3)**: the checked pair's route is not in the spec. For
  a dependency host, the spec is incomplete. For your own app's inbound
  pairs, this is the asymmetry above: route that side to
  proxymock-regression-test.
- **`undocumented field` notes**: the response carries fields the spec does
  not declare. Additive fields are usually non-breaking; escalate them to
  failures with `--fail-on-undocumented` when the spec is meant to be
  exhaustive. Running `proxymock validate` directly gives you the escalated
  behavior with no flag.
- **Green conformance is not a behavior gate.** Schema conformance checks
  shape, not values or ordering; a wrong-but-well-typed response passes.
  Pair with proxymock-regression-test for behavior.

## Related

- **quality-loop**: the router; its `contract` route dispatches here, and
  its doctor checks the environment this skill assumes.
- **proxymock-regression-test**: the other side of the asymmetry; when the
  app has no spec, the recording is the contract and replay is the gate.
- **proxymock-summarize-recording**: see what hosts and routes a recording
  contains before pointing `--in` at it.

## Proof

```bash
./skills/proxymock-contract-test/scripts/prove-proxymock-contract-test.sh
```

The proof is hermetic (no app build, no network, no cloud). It checks the
committed recording's outbound pairs against the committed `lab/openapi.yaml`
and verifies 5/5 conformant (exit 0); seeds `stars: "many"` into a copied
pair and verifies exit 2 with the exact violation string; checks a pair
whose route the spec lacks and verifies exit 3 with the pair named; seeds an
undocumented field and verifies it is a note by default (exit 0) and a
violation under `--fail-on-undocumented` (exit 2); generates mocks from the
committed spec, verifies non-empty 200 bodies, that the generated pairs
validate against the spec they came from, and a clean mock load via
`--serve` (then tears it down); and verifies a missing `--spec` exits 4.
