# Diagnose and fix the catalog API regression

`GET /api/catalog/stats` is functionally correct but becomes CPU-bound when the
downstream catalog is large. Diagnose the bottleneck and implement a fix.

Use both connected data sources:

1. Use Grafana/Pyroscope to find the functions and source lines consuming CPU
   during a proxymock load replay. Read the baseline interval from
   `proxymock/results/baseline/load/profile-window.json`. If it is missing, do
   not infer timestamps or rely on inherited directory settings. Run
   `make load-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/baseline`
   and proceed only if it succeeds and creates the file.
2. Use proxymock's local recording to understand the real input shape. Keep the
   mock in `--no-passthrough` mode so the downstream cannot hide nondeterminism.
3. Make the smallest maintainable code change that removes the bottleneck.
4. Run unit tests and a three-request functional replay.
5. Use proxymock `response_diff` against the baseline functional replay. A 200
   status and matching schema are insufficient; stable response values must not
   change.
6. Run the same 8-VU, 45-second load replay with
   `make load-replay RECORDING_DIR=proxymock/recording RESULTS_DIR=proxymock/results/candidate`.
   Proceed only if the command succeeds. Read the generated
   `load/profile-window.json`, subtract 15 seconds from `start`, add 15 seconds
   to `end`, and query the new CPU profile over that buffered window. Do not ask
   the user to copy timestamps.

Report the before/after latency and throughput, the original hotspot, the new
top application work, and any semantic differences.
