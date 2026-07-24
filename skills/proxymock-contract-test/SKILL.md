---
name: proxymock-contract-test
description: Contract-test with traffic plus an OpenAPI spec, in two directions. Mode mock-from-spec wraps proxymock generate so a consumer can mock a dependency straight from its spec before any recording exists; mode conformance validates recorded or replayed RRPair response bodies against the spec with a bundled checker (proxymock has no native traffic-vs-spec path), reporting exact JSON-path violations. Use when users ask whether a dependency's behavior matches its spec, to validate recorded traffic against an OpenAPI contract, or to mock an API from its spec alone.
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
- **conformance**: the traffic is judged by the spec. A bundled checker
  validates recorded (or replayed) RRPair response bodies against the spec's
  schemas and reports violations with exact JSON-path attribution.

proxymock has NO native traffic-vs-spec path today: nothing in
`generate`/`report`/`replay`/`files compare`/`drift` accepts a spec, and
`--fail-if` is metrics-only. That is why conformance mode ships its own
checker (`scripts/check_conformance.py`, stdlib python3): type, required,
enum, and undocumented-field checks with `$ref` resolution. YAML specs are
converted via PyYAML when importable, else `ruby -ryaml`, else the script
asks for a `.json` spec; the fallback chain exists because system pythons
routinely lack PyYAML.

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

- `--spec`: the OpenAPI 3.0+ spec, `.json` or `.yaml`.
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

`conformance` (forwarded to the bundled checker):

- `--in`: the RRPair directory to check. Point it at the recording's
  dependency host subdir (e.g. `recording/demo-api.trafficreplay.com`), a
  whole recording, or a replay output dir.
- `--paths`: regex; only pairs whose request path matches are checked.
  Scope this to the routes the spec covers when the directory mixes hosts.
- `--fail-on-undocumented`: response fields absent from the spec's
  `properties` become violations instead of notes.

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
`./skills/proxymock-contract-test` with the copied skill directory; the
script finds `check_conformance.py` relative to its own location. The
scripts also source shared helpers from `skills/lib/common.sh` (resolved as
`../../lib/common.sh` relative to the scripts), so copy that file alongside.

## Measured limits of generated mocks

`proxymock generate` output is **smoke/plumbing tier**: good for developing
against a dependency before any recording exists, proving wiring, and
exercising client code paths. It is not logic-grade data. All measured:

- **Required-only bodies by default.** Optional properties are omitted;
  pass `--include-optional` for fuller payloads.
- **Arrays are 2 identical stub items.** An app aggregating over them sees
  degenerate distributions.
- **Example-less enum fields get the literal `"example_value"`, which
  violates the spec's own enum.** Apps that branch on enum values will see
  impossible data (the lab app's `/api/stats` aggregated the stubs into
  `by_maturity: {example_value: 2}`). The script warns in its output when
  the spec has enums without examples, naming each location; fix by adding
  `example:` next to each enum.
- **The spec's https servers are emitted as `http://:80` in the
  artifacts.** Signature matching still works, so the mock serves fine;
  just do not read the artifact URLs as the real scheme.
- **One response per status.** No response variety within a status code.
- **Path params become match-any templates** (`${{param:id}}` matches any
  concrete id), including params the spec constrains with an enum.

## Output contract

Written to `--work-dir`:

- `conformance`: `summary.json` (per-pair verdicts, violation strings,
  counts, exit code); per-pair verdict lines on stdout, violations with
  exact JSON path, field, expected type, and actual value, e.g.
  `$[0].stars: type mismatch, expected integer, got str ('many')`.
- `mock-from-spec`: the generated RRPairs (`generated/` unless `--out`),
  `generate.log`, `summary.json` (pair count, mock command), and with
  `--serve`: `serve.json` (pid, ports) and `mock.log`.

Exit codes:

- `0`: mock-from-spec succeeded (and, with `--serve`, the mock loaded);
  conformance found every checked pair conformant.
- `2`: conformance violations found.
- `3`: no violations, but the spec has no route for at least one checked
  pair (partial coverage; each `NO_ROUTE` pair is named).
- `4`: precondition/usage error (bad args, unreadable spec, generate
  produced nothing, `--serve` mock failed to load).

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
  exhaustive.
- **enum warning from mock-from-spec**: the generated mock will serve
  `"example_value"` for those fields; either add `example:` values to the
  spec or treat affected flows as plumbing-only.
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
whose route the spec lacks and verifies exit 3 with the pair named;
generates mocks from the committed spec, verifies non-empty 200 bodies, the
enum-without-example warning, and a clean mock load via `--serve` (then
tears it down); and verifies a missing `--spec` exits 4.
