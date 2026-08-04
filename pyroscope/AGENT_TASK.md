# Diagnose and fix the catalog API regression

`GET /api/catalog/stats` is functionally correct but becomes CPU-bound when the
downstream catalog is large. Diagnose the bottleneck and implement a fix.

Use both connected data sources:

1. Use Grafana/Pyroscope to find the functions and source lines consuming CPU
   during a proxymock load replay.
2. Use proxymock's local recording to understand the real input shape. Keep the
   mock in `--no-passthrough` mode so the downstream cannot hide nondeterminism.
3. Make the smallest maintainable code change that removes the bottleneck.
4. Run unit tests and a three-request functional replay.
5. Use proxymock `response_diff` against the baseline functional replay. A 200
   status and matching schema are insufficient; stable response values must not
   change.
6. Run the same 8-VU, 45-second load replay. Read the generated
   `load/profile-window.json`, subtract 15 seconds from `start`, add 15 seconds
   to `end`, and query the new CPU profile over that buffered window. Do not ask
   the user to copy timestamps.

Report the before/after latency and throughput, the original hotspot, the new
top application work, and any semantic differences.
