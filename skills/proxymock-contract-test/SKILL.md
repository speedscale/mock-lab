---
name: proxymock-contract-test
description: Contract-test recorded or replayed traffic against an OpenAPI spec with proxymock validate, reporting exact JSON-path violations, and mock a dependency straight from its spec with proxymock generate before any recording exists. Use when users ask whether a dependency's behavior matches its spec, to validate recorded traffic against an OpenAPI contract, or to mock an API from its spec alone.
argument-hint: --spec <openapi.(json|yaml)> --in <rrpair-dir>
---

# proxymock Contract Test

Contract testing from the assets the quality loop already has: an OpenAPI 3.0+
spec and RRPair traffic. One native command:

```bash
proxymock validate --spec ./openapi.yaml --in ./proxymock/recording/<dependency-host>
```

It matches each HTTP RRPair to a method and route in the spec (path templates
included), checks the response body for type, required fields, enum values and
undocumented fields, resolves local and component `$ref`s, and parses YAML
itself — no PyYAML, no `ruby -ryaml`.

**Requires proxymock v2.5.814 or newer.**

## Read this first: the contract is one-sided

`validate` checks traffic against **the DEPENDENCY's spec** — the spec
describes the API your app *calls*, and the recording's outbound pairs are the
evidence.

Your app's own inbound API usually has no spec, so **its contract is the
recording**. Route that side to **proxymock-regression-test** (replay the
recording at the app and diff), not here. In practice the asymmetry shows up as
`NO_ROUTE` pairs and exit 3: pointing `validate` at the recording's
`localhost/` subdir reports 8 pairs, 0 conformant, 8 without a spec route.
Point it at the dependency host subdir instead.

## Works with your stack (no bash required)

```bash
# does the dependency's recorded behavior match its spec?
proxymock validate --spec lab/openapi.yaml \
  --in lab/proxymock/recording/demo-api.trafficreplay.com

# same check against a replay output dir: a violation introduced between
# recording and replay is a change your code made
proxymock validate --spec lab/openapi.yaml --in ./regress-run
```

| Exit | Meaning |
| --- | --- |
| `0` | every checked pair conformant |
| `2` | violations found (each printed with its exact JSON path) |
| `3` | no violations, but at least one pair's route is missing from the spec (`NO_ROUTE`) |
| `1` | precondition failure: unreadable spec, missing directory, no HTTP pairs |

Violations print with full attribution, e.g.
`$[0].stars: type mismatch, expected integer, got string ("many")`, and the run
ends with `checked 5 pair(s): 4 conformant, 1 violating, 0 without a spec
route`. Any CI system in any language can gate on those exit codes; the repo's
`quality-loop.sh contract` is optional convenience that builds this exact line.

**`validate` treats undocumented response fields as violations.** There is no
flag to downgrade them. If additive response fields are non-breaking for you,
filter them out of the report yourself or expect the exit 2 and read the
violation list rather than the code.

## Mocking a dependency from its spec, before any recording exists

```bash
proxymock generate --spec ./openapi.yaml --out ./generated --include-optional
proxymock mock --in ./generated
```

Generated output is **smoke/plumbing tier**: good for developing against a
dependency before a recording exists, proving wiring, and exercising client
code paths. It is not logic-grade data. All measured:

- **Required-only bodies by default.** Pass `--include-optional` for fuller
  payloads.
- **Arrays are 2 identical stub items.** An app aggregating over them sees a
  degenerate distribution.
- **Example-less fields get the literal `"example_value"`.** Enum fields are
  the exception — they get a real member of their enum, so generated bodies
  pass `validate` against the spec they came from. Add `example:` values where
  a plausible string matters.
- **One response per status.** No response variety within a status code.
- **Path params become match-any templates** (`${{param:id}}` matches any
  concrete id), including params the spec constrains with an enum.

## Interpretation

- **VIOLATION on recorded traffic**: the dependency drifted from its spec, or
  the spec is stale. The recording is evidence of real behavior, so treat it as
  "spec and reality disagree" and decide which is wrong; the JSON path names
  the exact field.
- **VIOLATION on replayed traffic**: same check, but the responses came from
  your mock or your app under test, so a violation introduced between recording
  and replay is a change your code made.
- **NO_ROUTE (exit 3)**: for a dependency host, the spec is incomplete. For
  your own app's inbound pairs, this is the asymmetry above — route that side
  to proxymock-regression-test.
- **undocumented-field violations**: additive response fields are usually
  non-breaking, but `validate` scores them as violations regardless. Decide
  from the violation text, not from the exit code alone.
- **Green conformance is not a behavior gate.** Schema conformance checks
  shape, not values or ordering; a wrong-but-well-typed response passes. Pair
  with proxymock-regression-test for behavior.

## Related

- **proxymock-regression-test**: the other side of the asymmetry; when the app
  has no spec, the recording is the contract and replay is the gate.
- **proxymock-summarize-recording**: see what hosts and routes a recording
  contains before pointing `--in` at it.
- **quality-loop**: the router, and its `doctor`.

## Proof

```bash
./skills/quality-loop/scripts/prove-quality-loop.sh
```

One shared proof covers this pack (a documented deviation from the repo's
one-prove-per-skill convention: every skill runs the same native binary now).
The cases covering this skill check the committed recording's dependency pairs
against the committed `lab/openapi.yaml` and verify 5/5 conformant at exit 0;
seed `stars: "many"` into a copy and verify exit 2 with the exact violation
string; and point the same spec at the recording's `localhost/` subdir to
verify the asymmetry lands as exit 3 with `NO_ROUTE` pairs named.
