# Validate Kubernetes allocation cost with recorded traffic

Compare the baseline and candidate resource allocations for `catalog-api`.
The application image and traffic must remain identical; only Kubernetes CPU
and memory requests and limits may differ.

1. Run the three-request functional replay for each allocation.
2. Through proxymock MCP, call `response_diff` on the baseline and candidate
   functional result directories. Inspect every stable-field difference; matching
   status codes or schemas alone are insufficient.
3. Run the load replay for each allocation. The command writes the exact UTC
   interval to that variant's `load/window.json`; never ask the user to record
   or provide timestamps.
4. Read each `window.json` yourself. Programmatically construct the MCP
   `window` argument as `file.start + "," + file.end`, then call
   `get_allocation_costs` with `aggregate="namespace"`, `step="1m"`, and
   `accumulate=true`. Select `catalog-api`. If it is absent, wait for ingestion
   and repeat the identical call without widening the interval or inferring
   timestamps from file or pod age.
5. For each variant, report total allocation cost divided by the replay's
   successful-request count, alongside p95 latency, throughput, and failures.

Declare the candidate valid only when functional replay has no failed requests,
`response_diff` has no stable-field changes, load replay satisfies the same
250 ms p95 and zero-failure SLO, and the exact-window allocation cost per
successful request is lower.

Treat the fixed rates as a reproducible allocation model, not a cloud bill or a
forecast of production savings.
