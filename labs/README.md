# labs/

Companion scenarios. Each directory has its own README and is independent of the ten-language CNCF-projects demo under [`languages/`](../languages/).

| Lab | What it demonstrates |
| --- | --- |
| [pyroscope](pyroscope/README.md) | CPU profile + proxymock replay to find a bottleneck, prove the response did not change, and measure again |
| [prometheus](prometheus/README.md) | p95 latency from connection queueing, not CPU |
| [tempo](tempo/README.md) | a serial dependency waterfall made visible in traces |
| [loki](loki/README.md) | a rare retry path that never fails the response contract — evidence is only in the logs |
| [hubble](hubble/README.md) | a request timeout caused by a Cilium network policy, not the application |
| [obi](obi/README.md) | eBPF instrumentation of an opaque service with no OpenTelemetry SDK |
| [credentials](credentials/README.md) | Re-sign JWTs, refresh opaque bearer tokens and replay HTTP Basic credentials in an independent Node app |
| [contract-testing](contract-testing/README.md) | Compare a deliberately invalid vendor capture with the clean baseline using an OpenAPI contract |
| [sqlcommenter](sqlcommenter/README.md) | which inbound request ran each SQL query, exactly, from the trace id the app writes into a SQL comment |
| [chaos](chaos/README.md) | Node coverage that misses a failed dependency, scoped chaos to expose it, and a bounded latency requirement |

The reference API and traffic tools live in [shared/](../shared/README.md). The reusable baseline lives in the root [proxymock workspace](../proxymock/README.md).
