# Demo script: diagnose with Pyroscope, prove with proxymock

This is a presenter-ready version of the Pyroscope and proxymock walkthrough.
It follows the same workflow as the how-to while adding the explanation an
audience needs to understand why each piece of evidence matters.

Allow 25 to 35 minutes. The commands assume the repository has been cloned and
the current directory is `mock-lab/pyroscope`.

## What the audience should learn

By the end of the demo, the audience should understand that an AI coding agent
needs more than source code and an error report:

- A CPU profile identifies where the running program spends CPU time.
- Recorded traffic shows the input shape and behavior that produced the cost.
- A repeatable replay measures the effect under the same workload.
- A response diff checks that an optimization preserved stable behavior.
- A second profile confirms that the original hotspot actually moved.

The point is not that an agent can read a flamegraph. The point is that the
agent can use independent evidence that is capable of disagreeing with its
proposed fix.

## Presenter preparation

### Required tools

- Go 1.23 or newer
- Docker with Compose
- `curl`
- An installed and activated `proxymock` binary
- A coding agent with the proxymock and Grafana MCP servers configured

For a live recording, use three terminals:

1. Catalog or mock process
2. proxymock process and application
3. Replay commands and the coding agent

Open Grafana at <http://localhost:3000> in advance. The local credentials are
`admin` / `admin`.

### Confirm that the intentional issue exists

Do this privately before the demo:

```shell
rg -n "for _, existing := range unique" internal/stats/stats.go
go test ./...
go test -run '^$' -bench '^BenchmarkBuild$' ./internal/stats
```

The source should contain a nested scan in `deduplicateProjects`, and the
benchmark should be tens of milliseconds per operation on typical developer
hardware. If the function contains a `seen` map, the demo has already been
fixed and will not produce the intended hotspot.

### Check for leftover processes

```shell
docker compose ps
lsof -nP -iTCP:6060 -iTCP:8080 -iTCP:8090 -sTCP:LISTEN
```

Stop processes from an earlier run before starting. In particular, a catalog
still listening on port 8090 will make `make catalog` fail.

### Choose the recording path

The repository includes a known-good recording as a fallback. For a fully live
demo, keep new traffic separate so the fallback is not mixed with the new run.
Run this in each terminal that will invoke a `make` target:

```shell
export RECORDING_DIR=.run/recording
```

The Makefile will then use the isolated path for recording, mocking, and both
replays. Alternatively, pass `RECORDING_DIR=.run/recording` to each `make`
command. If time is limited, skip the recording section and use the committed
`proxymock/recording` directory.

## Opening: one kind of evidence is not enough

**Say:**

> This endpoint is correct, but it becomes CPU-bound with a large catalog. I
> could ask an AI agent to optimize the code from a vague symptom, but then I
> would be asking it to guess. Instead, I will give it two independent
> witnesses. Pyroscope will tell it where CPU is going. proxymock will tell it
> what workload caused the problem and whether the fix changes behavior.

Show `internal/stats/stats.go`, but do not point out the nested scan yet.

**Explain why this matters:**

Production symptoms are usually indirect. High latency could come from CPU,
network waits, lock contention, garbage collection, or a slow dependency.
Source code alone does not tell an agent which path dominates for real inputs.
Runtime evidence narrows the search before the agent edits anything.

## Act 1: create an observable, repeatable workload

### Step 1: start the profiling stack

In terminal 1:

```shell
make observability-up
```

Show that Grafana is available at <http://localhost:3000>.

**Say:**

> Grafana Alloy pulls Go's pprof endpoints from port 6060 and sends continuous
> profiles to Pyroscope. A CPU profile is sampled runtime data. Wider frames
> mean more CPU samples accumulated in that call path during the selected time
> range.

**Explain why someone would use this data:**

A profiler answers a causal localization question: which functions and source
lines account for CPU consumption in the running application? It prevents the
agent from optimizing code that merely looks suspicious but contributes little
to the observed problem.

It does not prove that a fix is behaviorally correct, and it does not fully
describe the input that triggered the path. That is why the demo needs traffic
data too.

### Step 2: record the API contract

In terminal 1, start the deterministic catalog:

```shell
make catalog
```

Point out that it reports 15,120 records. The data includes 12,000 unique
projects, duplicates, and 120 malformed records.

In terminal 2:

```shell
make record
```

If you chose the isolated live path, use:

```shell
make record RECORDING_DIR=.run/recording
```

In terminal 3:

```shell
curl http://localhost:4143/api/catalog/stats
```

The response should contain these stable values, regardless of JSON field
ordering:

```json
{
  "total_records": 15120,
  "valid_records": 15000,
  "unique_projects": 12000,
  "duplicates_removed": 3000,
  "invalid_records": 120,
  "by_category": {
    "database": 3000,
    "observability": 3000,
    "runtime": 3000,
    "security": 3000
  }
}
```

Stop `make record` with Ctrl-C. You can also stop `make catalog`; the real
dependency is no longer needed for the rest of the demo.

**Say:**

> proxymock observed both sides of this operation: the inbound stats request
> and the outbound catalog request with its large response. This recording is
> now an executable example of the workload and its behavior.

**Explain why someone would use this data:**

The traffic answers questions a profile cannot:

- How large was the downstream response?
- Were IDs unique, duplicated, or malformed?
- Which output totals and category counts must remain stable?
- Can the same dependency behavior be reproduced without the real service?

This matters because a fast but incorrect fix is easy. An agent could remove
validation, skip deduplication, or hard-code totals. Those changes might reduce
CPU and still return HTTP 200 with the same JSON schema. The recorded response
contains the edge cases needed to expose those shortcuts.

### Step 3: replace the dependency with the recording

In terminal 2:

```shell
make mock
```

For the isolated live path:

```shell
make mock RECORDING_DIR=.run/recording
```

**Say:**

> The application is now running against the recorded catalog with network
> passthrough disabled. Every candidate sees the same downstream input. If the
> real catalog changes or disappears, this experiment does not.

**Explain why someone would use this data:**

Determinism makes before-and-after measurements credible. Without it, a
candidate might appear faster because the dependency returned fewer records,
the network was quieter, or a remote cache was warm. `--no-passthrough` also
turns an unexpected dependency call into visible evidence instead of silently
letting the test escape to the network.

## Act 2: establish two different baselines

### Step 4: capture the correctness baseline

In terminal 3:

```shell
make functional-replay RESULTS_DIR=proxymock/results/baseline
```

**Say:**

> This three-request replay is the correctness run. Repetition helps identify
> fields such as Date that naturally vary. Later, response diff can focus on
> stable behavior rather than reporting expected noise.

**Explain why someone would use this data:**

Correctness is more than availability. Status codes and schemas detect gross
failures, but stable values detect semantic regressions. Here the important
contract includes totals, invalid counts, duplicate counts, and category
aggregates.

### Step 5: capture the performance baseline and exact time window

```shell
date -u +"%Y-%m-%dT%H:%M:%SZ"
make load-replay RESULTS_DIR=proxymock/results/baseline
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

Save the two timestamps where the audience can see them.

**Say:**

> This 8-VU, 45-second replay has a different job. It creates sustained CPU
> activity and gives us latency and throughput. I am recording the exact UTC
> interval so the agent queries the profile for this experiment, not an older
> run or idle time.

**Explain why someone would use this data:**

Functional and load evidence answer different questions:

- Functional replay asks, "Did behavior stay correct?"
- Load replay asks, "What did users experience under repeated work?"
- The CPU profile asks, "Where did the process spend its CPU while doing it?"

Do not use load mode as the semantic correctness check. It is optimized to
drive traffic and measure workload results, not to perform the full stable-field
comparison.

## Act 3: let the agent investigate before it edits

### Step 6: show how MCP connects the agent to evidence

If MCP is not already configured, run these commands from the lab directory:

```shell
codex mcp add proxymock -- proxymock mcp run --work-dir .
codex mcp add grafana -- docker run --rm -i \
  --add-host host.docker.internal:host-gateway \
  -e GRAFANA_URL=http://host.docker.internal:3000 \
  -e GRAFANA_USERNAME=admin \
  -e GRAFANA_PASSWORD=admin \
  grafana/mcp-grafana:0.14.0 -t stdio --disable-write \
  --enabled-tools datasource,pyroscope,navigation
codex mcp list
```

The equivalent server definitions are in `mcp.example.json`.

**Say:**

> MCP is the interface, not the evidence itself. The Grafana MCP server lets
> the agent discover the Pyroscope datasource and query profiles. The
> proxymock MCP server lets it search the local recording and compare replay
> results. The model still has to call those tools with the right datasource,
> matcher, path, and time range.

Point out that the Grafana server is read-only and restricted to datasource,
Pyroscope, and navigation tools. proxymock reads local artifacts from the demo
working directory.

### Step 7: ask for diagnosis, not a guess

Replace the interval in this prompt with the baseline timestamps. If you used
the isolated live recording, replace `proxymock/recording` with
`.run/recording`.

```text
Using the Grafana MCP server, find the Pyroscope datasource and available
profile types. Then call query_pyroscope for the Process CPU profile.

Use matcher {service_name="catalog-api"} and this exact baseline UTC interval:
START=<baseline start>
END=<baseline end>

Identify the hottest application functions and source lines. Before proposing
a fix, use the proxymock MCP server to inspect the recorded catalog traffic in
proxymock/recording. Describe the input size, duplicates, malformed records,
and stable response values that an optimization must preserve.

Explain how the profile and traffic evidence support the diagnosis. Do not edit
the code yet.
```

As the agent works, call out the expected tool sequence:

1. Discover the Grafana datasource instead of assuming its identity.
2. Discover available profile types instead of inventing a query type.
3. Query Process CPU for `{service_name="catalog-api"}` and the exact interval.
4. Inspect recorded traffic through proxymock.
5. Correlate profile frames with the implementation.

The expected diagnosis is that `deduplicateProjects` and string equality work
dominate CPU because each valid project scans the projects already accepted.
The large, mostly unique catalog turns that nested scan into quadratic work.

**Say:**

> The flamegraph localized the cost. The recorded input explained why this code
> path becomes expensive. Either source by itself would leave room for a bad
> inference: a hot function without input context, or a large payload without
> proof of where CPU goes.

If desired, open Grafana Profiles Drilldown and show the same baseline interval
visually. Use the UI to reinforce the agent's evidence, not as a separate run.

## Act 4: make the smallest evidence-backed fix

### Step 8: authorize the code change

Paste:

```text
Implement the smallest maintainable fix for the diagnosed CPU hotspot.
Preserve validation and first-valid-record deduplication semantics. Do not
hard-code catalog values or change tests to make them pass.

Run make test and the focused BenchmarkBuild benchmark. Explain the algorithmic
change, the benchmark result, and which externally visible behavior should
remain unchanged.
```

The expected change replaces the nested membership scan with constant-time map
lookups.

**Explain why this matters:**

The prompt constrains both algorithm and behavior. "Make it faster" alone can
reward deletion of required work. Naming the invariants gives the agent a
boundary, while the tests and benchmark provide fast local feedback before the
more expensive end-to-end validation.

When the agent reports a faster benchmark, say:

> This is evidence that the local function became faster. It is not yet
> evidence that the API is correct, that replay latency improved, or that the
> original production hotspot disappeared.

## Act 5: make the candidate prove itself

### Step 9: restart the candidate against the same mock

Stop the current `make mock` process with Ctrl-C, then restart it so the Makefile
builds the candidate:

```shell
make mock
```

For the isolated live path:

```shell
make mock RECORDING_DIR=.run/recording
```

### Step 10: give the agent the validation prompt

```text
Validate the candidate using both proxymock and Grafana/Pyroscope. Do not edit
the application code during this validation.

1. Run:
   make functional-replay RESULTS_DIR=proxymock/results/candidate
2. Through the proxymock MCP server, call response_diff to compare:
   - proxymock/results/baseline/functional
   - proxymock/results/candidate/functional
   Report every stable-field difference. Do not treat matching status codes or
   response schemas as proof of correctness.
3. Record the exact UTC start time, run:
   make load-replay RESULTS_DIR=proxymock/results/candidate
   Then record the exact UTC end time.
4. Through the Grafana MCP server, query the Pyroscope Process CPU profile for
   matcher {service_name="catalog-api"} over that exact candidate interval.
5. Compare candidate latency, throughput, failed requests, response diff, and
   CPU hotspots with the baseline evidence from earlier in this session.

Report the evidence in a before-and-after table. Declare the candidate valid
only if there are no failed functional requests, no stable response changes,
and the original application hotspot is absent or materially reduced.
```

If the agent cannot execute the `make` commands, run these manually and give it
the exact candidate interval:

```shell
make functional-replay RESULTS_DIR=proxymock/results/candidate
date -u +"%Y-%m-%dT%H:%M:%SZ"
make load-replay RESULTS_DIR=proxymock/results/candidate
date -u +"%Y-%m-%dT%H:%M:%SZ"
```

### Step 11: interpret the evidence with the audience

The reference run produced:

| Evidence | Baseline | Correct candidate |
| --- | ---: | ---: |
| Core benchmark | 83.9 ms/op | 0.69 ms/op |
| Average replay latency | 168.2 ms | 13.0 ms |
| Replay throughput | 47.3 req/s | 591.3 req/s |
| Failed requests | 0 | 0 |
| Stable response changes | baseline | none |
| Dominant application CPU | deduplication | JSON decoding |

Treat these values as directional. Compare both versions on the same machine.

Walk through what each row proves:

- **Benchmark:** the focused algorithm changed materially.
- **Latency and throughput:** the same external workload became faster.
- **Failed requests:** the candidate remained available during replay.
- **Stable response diff:** totals and aggregates did not silently change.
- **Second CPU profile:** the original hotspot is gone and unavoidable work,
  such as JSON decoding, now dominates.

**Important flamegraph caveat:**

Do not compare only normalized frame widths between the baseline and candidate.
The candidate processes many more requests during the same 45 seconds, so it
performs more total JSON decoding. A frame can occupy a larger percentage of a
new profile even when per-request latency improved. Use proxymock for absolute
workload metrics and Pyroscope for source-level CPU attribution.

## Closing: evidence that can reject the fix

**Say:**

> Pyroscope found the expensive code. The recorded traffic explained the input
> that made it expensive. Replay measured the improvement. Response diff made
> sure we did not optimize away required behavior. The second profile confirmed
> that CPU moved somewhere expected. The agent did not become trustworthy
> because it wrote plausible code. It became useful because its change had to
> survive evidence that could prove it wrong.

The final takeaway is short:

> Flamegraphs find the problem. Replay proves the fix.

## Security note for a real environment

This lab uses disposable local credentials and synthetic traffic. In a real
environment:

- Use a scoped, read-only Grafana service account.
- Redact credentials, personal data, and secrets from recorded traffic.
- Limit the MCP tools and paths the agent can access.
- Retain an audit trail of profile queries, traffic access, code changes, and
  validation results.
- Decide explicitly where prompts, profiles, source snippets, and traffic may
  be processed and retained.

Profiles may expose function names, repository paths, and source lines.
Recorded traffic may expose payloads and credentials. Both are valuable
debugging evidence and should be governed accordingly.

## Cleanup and reset

Stop `make mock` and any remaining catalog process with Ctrl-C, then stop the
observability stack:

```shell
make observability-down
```

Review the candidate before resetting it:

```shell
git diff -- internal/stats/stats.go
```

To prepare this clean clone for another demo, discard only the agent's intended
change:

```shell
git restore internal/stats/stats.go
```

If the candidate is worth keeping, save its diff or commit it on a separate
branch before restoring the file.

## Recovery plan for a live presentation

- **The live recording fails:** use the committed `proxymock/recording` and
  continue from `make mock`.
- **Port 8090 is occupied:** stop the old catalog process; do not start a second
  one.
- **No profile appears:** confirm the application exposes pprof on port 6060,
  Alloy is running, and the query interval overlaps the load replay.
- **The agent queries the wrong data:** require datasource and profile-type
  discovery, matcher `{service_name="catalog-api"}`, and exact UTC timestamps.
- **The agent edits before inspecting traffic:** stop it and repeat the diagnosis
  prompt. The order is part of the demonstration.
- **The candidate changes stable values:** treat that as a failed candidate,
  even if latency and CPU improve.
- **The agent has already fixed the clone:** restore
  `internal/stats/stats.go` from `main` before presenting.
