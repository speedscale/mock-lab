# Prometheus + proxymock non-CPU latency task

Work in the `prometheus` directory of your `mock-lab` clone. Do not edit the
application until step 6.

1. Read `proxymock/results/baseline/load/window.json`. Report `start` and
   `end` as the exact replay boundaries. The load target publishes a
   conservative whole-second query interval as `query_start`, `query_end`, and
   `window_seconds`, so no timestamp ever needs to be edited, rounded, or
   reasoned about by hand. Pass `query_end` unchanged as `endTime` and use
   `window_seconds` unchanged as the PromQL range below, written `[<window_seconds>s]`.
2. Call `list_datasources` with `{"type":"prometheus","limit":50,"offset":0}`.
3. Call `list_prometheus_metric_names` with
   `{"datasourceUid":"prometheus","regex":"^(checkout_request_duration_seconds|pricing_conn_wait_seconds)(_bucket|_count|_sum)?$|^app_cpu_seconds_total$","limit":50,"page":1}`.
4. Run these four `query_prometheus` calls with
   `{"datasourceUid":"prometheus","queryType":"instant","endTime":file.query_end,"expr":...}`:
   - Symptom:
     `histogram_quantile(0.95, sum by (le) (increase(checkout_request_duration_seconds_bucket{route="/api/quote"}[<window_seconds>s])))`
   - Cause:
     `histogram_quantile(0.95, sum by (le) (increase(pricing_conn_wait_seconds_bucket[<window_seconds>s])))`
   - Compute:
     `increase(app_cpu_seconds_total[<window_seconds>s]) / <window_seconds>`
   - Errors:
     `sum(increase(checkout_request_duration_seconds_count{route="/api/quote",code!="200"}[<window_seconds>s]))`
   Report p95 request duration, p95 connection wait, average cores, and the
   error count (an empty result means no error series was created). State
   whether the wait accounts for the latency and whether CPU could. Take exact
   request counts from `summary.json`; `increase()` extrapolates counts and is
   only a magnitude cross-check.
5. Before proposing any fix, call proxymock MCP `search_local_traffic` for
   inbound `GET /api/quote` traffic and outbound `GET /v1/price/` traffic under
   `proxymock/recording`. Report the recorded dependency boundary and its
   response time, and explain why request queueing multiplies it.
6. Make the smallest change in `internal/checkout/checkout.go` that removes
   connection-acquisition queueing at 8 concurrent requests. Preserve
   validation, error mapping, response values, and every metric. Do not change
   the pricing fixture, the recording, or any replay parameter. Run `make test`.
7. Restart `make mock` so it rebuilds the candidate, then run:
   `make functional-replay RESULTS_DIR=proxymock/results/candidate` and
   `make load-replay RESULTS_DIR=proxymock/results/candidate`.
8. Call proxymock MCP `response_diff` with the baseline `functional` directory
   as baseline and the candidate `functional` directory as candidate. Report
   every stable-field difference; matching status codes are insufficient.
9. Read `proxymock/results/candidate/load/window.json` and repeat the four
   queries from step 4 with its `query_end` and `window_seconds`, both
   unchanged. Build one before-and-after table: p95 request duration, p95
   connection wait, average cores, failed requests, replay average latency,
   and replay throughput. Declare success only if the candidate has zero
   failed requests, zero stable-field differences, and both the p95 and the
   causal wait metric improved under the identical 1200-request workload.

If a query is empty, repeat the identical query at most three times. Do not
change, widen, copy, or ask the user to confirm the interval. Inspect the
Prometheus target and `docker compose logs prometheus` read-only if the same
query stays empty.
