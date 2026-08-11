# Agent task: diagnose serial inventory calls with Tempo and proxymock

Work from `/Users/matthewleray/s2/mock-lab/tempo`.

The acceptance gates are:

- Inspect the recorded inbound and dependency traffic through proxymock MCP
  before editing application code.
- Query the baseline trace through Grafana MCP over the exact interval in
  `proxymock/results/baseline/functional/window.json`.
- Preserve validation, response order, and response values.
- Run unit tests plus functional and load replays for the candidate.
- Report every stable-field difference from proxymock `response_diff`.
- Compare latency, throughput, span count, downstream fan-out, trace shape, and
  critical path.

Start with this prompt:

```text
Work in /Users/matthewleray/s2/mock-lab/tempo. Do not edit application code yet.

1. Call proxymock MCP search_local_traffic with:
   {"in-directory":["/Users/matthewleray/s2/mock-lab/tempo/proxymock/recording"],"direction":"in","method":"POST","query":"product_ids","limit":20,"offset":0}
2. Call it again with:
   {"in-directory":["/Users/matthewleray/s2/mock-lab/tempo/proxymock/recording"],"direction":"out","method":"GET","query":"/v1/inventory/","limit":20,"offset":0}
3. Read the inbound RRPair file returned by the first call. Explain exactly why
   that input produces the repeated dependency operations and whether their
   timestamps are serial or overlapping.

Then call Grafana MCP list_datasources with:
{"type":"tempo","limit":50,"offset":0}

Parse /Users/matthewleray/s2/mock-lab/tempo/proxymock/results/baseline/functional/window.json yourself. Pass file.start and file.end directly, unchanged, to Grafana MCP tempo_traceql-search with:
{"datasourceUid":"tempo","query":"{ resource.service.name = \"catalog-api\" && name = \"POST /api/catalog\" }","start":file.start,"end":file.end}

Do not ask me to record, copy, substitute, widen, round, or confirm timestamps.
Choose the longest returned trace, then call tempo_get-trace with:
{"datasourceUid":"tempo","trace_id":the returned traceID}

Report the trace ID, root critical-path duration, total span count, count of
inventory.lookup and GET inventory spans, downstream fan-out, whether calls
overlap, service.name, instrumentation scope/version, code.file.path, and
code.function.name. Do not propose a fix until both MCP investigations are done.
```

After the evidence is reported, use this prompt:

```text
Implement the smallest maintainable bounded-concurrency fix in
/Users/matthewleray/s2/mock-lab/tempo/internal/catalog/catalog.go.

Pin the only new dependency first with:
go get golang.org/x/sync@v0.16.0

Preserve input validation, output order, cancellation, error propagation, and
every response value. Do not hard-code product IDs or quantities. Do not weaken
or rewrite tests merely to pass. Add a focused test proving the concurrency
bound and run make test.

Then restart make mock against the same proxymock/recording and run:
make functional-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/candidate
make load-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/candidate

Call proxymock MCP response_diff with:
{"baseline-directory":["/Users/matthewleray/s2/mock-lab/tempo/proxymock/results/baseline/functional"],"in-directory":["/Users/matthewleray/s2/mock-lab/tempo/proxymock/results/candidate/functional"]}
Report every stable-field difference; matching status or schema is insufficient.

Parse candidate/functional/window.json and pass its start and end directly and
unchanged to tempo_traceql-search using datasourceUid tempo and the same TraceQL
query. Choose the longest trace and call tempo_get-trace. Do not ask me for a
timestamp.

Build one before-and-after table from the two functional/summary.json files,
the two load/summary.json files, response_diff, and both traces. Include failed
functional requests, stable differences, average load latency, load throughput,
load failures, trace IDs, span count, repeated operation count, fan-out, trace
shape, and critical path. Declare success only if every gate has evidence.
```
