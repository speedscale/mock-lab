# Loki + proxymock rare retry path task

Work in the `loki` directory of your `mock-lab` clone. Do not edit the
application until step 6.

1. Read `proxymock/results/baseline/load/window.json`. Report `start` and
   `end` as the exact replay boundaries. The replay targets publish a
   conservative whole-second query interval as `query_start`, `query_end`, and
   `window_seconds`, so no timestamp ever needs to be edited, rounded, or
   reasoned about by hand. Pass `query_start` unchanged as `startRfc3339` and
   `query_end` unchanged as `endRfc3339` on every Loki call below, and use
   `window_seconds` unchanged as the LogQL range, written `[<window_seconds>s]`.
2. Call `list_datasources` with `{"type":"loki","limit":50,"offset":0}`.
3. Call `list_loki_label_names` for that datasource over the same interval and
   report the stream labels that exist.
4. Run these `query_loki_logs` calls with
   `{"datasourceUid":"loki","queryType":"instant","startRfc3339":file.query_start,"endRfc3339":file.query_end,"logql":...}`:
   - Level shape:
     `sum by (level) (count_over_time({service="checkout"} | json [<window_seconds>s]))`
   - Anomalous events:
     ``sum by (event) (count_over_time({service="checkout"} | json | level =~ `WARN|ERROR` [<window_seconds>s]))``
   - What triggers them:
     ``sum by (sku, dep_state) (count_over_time({service="checkout"} | json | event = `pricing_retry_exhausted` [<window_seconds>s]))``
   - What it costs:
     ``quantile_over_time(0.95, {service="checkout"} | json | event = `quote_served` | unwrap duration_ms [<window_seconds>s]) by (price_source)``
   - How often the rare path runs:
     ``sum by (price_source) (count_over_time({service="checkout"} | json | event = `quote_served` [<window_seconds>s]))``
   Report the counts per level, the events behind them, the SKU and dependency
   state that produce them, and the p95 served duration per price source. Take
   the exact request total from `proxymock/results/baseline/load/summary.json`.
   State whether this is an error condition or a state transition the service
   is handling.
5. Correlate one occurrence end to end before proposing anything. Call
   `query_loki_logs` with `queryType="range"`, `direction="forward"`,
   `limit=20`, and
   ``{service="checkout"} | json | event = `pricing_retry_exhausted` ``
   to obtain one `request_id`, then query
   ``{service="checkout"} | json | request_id = `<that id>` `` to read the whole
   chain in order. Then call proxymock MCP `search_local_traffic` under
   `proxymock/recording` for the inbound `GET /api/quote` traffic and for the
   outbound `GET /v1/price/` traffic of the SKU the logs named. Report the
   recorded dependency response body that triggers the path, and state which
   field of that body makes the retries unnecessary. The triggering input must
   come from the recording, not from a value you invent.
6. Make the smallest change in `internal/checkout/checkout.go` that removes the
   unnecessary retries. Preserve input validation, the error path when the
   dependency publishes no usable price, the resolved price, and a log line
   that still records the state transition — do not silence the signal, and do
   not change the response contract. Run `make test`.
7. Restart `make mock` so it rebuilds the candidate, then run:
   `make functional-replay RESULTS_DIR=proxymock/results/candidate`,
   `make load-replay RESULTS_DIR=proxymock/results/candidate`, and
   `make verify RESULTS_DIR=proxymock/results/candidate`.
8. Call proxymock MCP `response_diff` with the baseline `functional` directory
   as baseline and the candidate `functional` directory as candidate. Report
   every stable-field difference; matching status codes are insufficient.
9. Read `proxymock/results/candidate/load/window.json` and repeat the step 4
   queries with its `query_start`, `query_end`, and `window_seconds`, all
   unchanged. Build one before-and-after table: lines per level, WARN and ERROR
   events by name, quotes by price source, p95 served duration per price
   source, failed requests, and replay latency. Declare success only if the
   candidate has zero failed requests, zero stable-field response differences,
   an unchanged split of quotes by price source, and materially fewer retry
   lines.

If a query returns no data, repeat the identical query at most three times. Do
not change, widen, copy, or ask the user to confirm the interval. If the same
query stays empty, inspect `docker compose logs alloy` and
`docker compose logs loki` read-only and stop.
