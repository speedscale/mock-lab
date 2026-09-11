# labs/

Companion scenarios. Each directory has its own README and is independent of the seven-language CNCF-projects demo under [`languages/`](../languages/).

| Lab | What it demonstrates |
| --- | --- |
| [pyroscope](pyroscope/README.md) | CPU profile + proxymock replay to find a bottleneck, prove the response did not change, and measure again |
| [prometheus](prometheus/README.md) | p95 latency from connection queueing, not CPU |
| [tempo](tempo/README.md) | a serial dependency waterfall made visible in traces |
| [loki](loki/README.md) | a rare retry path that never fails the response contract — evidence is only in the logs |
| [hubble](hubble/README.md) | a request timeout caused by a Cilium network policy, not the application |
| [obi](obi/README.md) | eBPF instrumentation of an opaque service with no OpenTelemetry SDK |
| [chaos](chaos/README.md) | a scoped chaos rule that forces the storefront's unused inventory-fallback path to run |

The shared CNCF fixture (`server/`, recordings, OpenAPI spec) stays in [`lab/`](../lab/), one level up.
