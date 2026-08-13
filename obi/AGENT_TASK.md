# OBI + proxymock investigation task

Work in the `obi` directory of your `mock-lab` clone. Do not edit the
application.

1. Read `proxymock/recording/window.json`. Report `capture_start` and
   `capture_end` as the exact recording boundaries. Pass `query_start` and
   `query_end` unchanged to every Grafana MCP time-range argument below. The
   capture script publishes this conservative, whole-second query interval so
   no timestamp ever needs to be edited, rounded, or reasoned about by hand.
2. Call `list_datasources` with
   `{"type":"prometheus","limit":50,"offset":0}`, then with
   `{"type":"tempo","limit":50,"offset":0}`.
3. Call `list_prometheus_metric_names` with
   `{"datasourceUid":"prometheus","regex":"^http_(server|client)_request_duration_seconds(_bucket|_count|_sum)?$","limit":50,"page":1}`.
4. Use `query_prometheus` range queries over the unchanged file interval to
   retrieve count, error-status, and duration-sum series for `catalog-api` and
   `catalog-fixture`. Use `stepSeconds:1`. For an existing series, calculate
   count and sum deltas from the first and last samples. If the request creates
   a series inside the interval, its first visible count and sum are the
   interval values. Report count, count divided by query seconds as rate, 5xx
   count, and mean duration per route.
5. Call the proxied Tempo tool `tempo_traceql-search` with
   `{"datasourceUid":"tempo","query":"{ resource.service.name = \"catalog-api\" && name = \"GET /api/stats\" }","start":file.query_start,"end":file.query_end}`.
   Retrieve the returned trace with `tempo_get-trace` using
   `{"datasourceUid":"tempo","trace_id":traceID}`.
6. Before proposing any source instrumentation, call proxymock MCP
   `search_local_traffic` for inbound `GET /api/stats` traffic and outbound
   `GET /v1/projects` traffic under `proxymock/recording`. Explain which
   recorded dependency boundary accounts for the latency.
7. Run `make functional-replay` and `make load-replay`, then report the
   functional response-match gate and replay latency/throughput. Functional
   semantics come from proxymock, not from the presence of telemetry.

If a query is empty, repeat the identical query at most three times. Do not
change, widen, copy, or ask the user to confirm the interval. Inspect OBI,
Tempo, Prometheus, and Grafana health if the same query stays empty.
