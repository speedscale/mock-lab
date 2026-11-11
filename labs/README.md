# labs/

Companion scenarios. Each directory has its own README and is independent of the ten-language CNCF-projects demo under [`languages/`](../languages/).

| Lab | What it demonstrates |
| --- | --- |
| [ai-refactor](ai-refactor/README.md) | Use an agent and proxymock replay to catch a typed-client refactor that returns HTTP 200 with an empty response field |
| [pyroscope](pyroscope/README.md) | CPU profile + proxymock replay to find a bottleneck, prove the response did not change, and measure again |
| [prometheus](prometheus/README.md) | p95 latency from connection queueing, not CPU |
| [tempo](tempo/README.md) | a serial dependency waterfall made visible in traces |
| [loki](loki/README.md) | a rare retry path that never fails the response contract — evidence is only in the logs |
| [hubble](hubble/README.md) | a request timeout caused by a Cilium network policy, not the application |
| [obi](obi/README.md) | eBPF instrumentation of an opaque service with no OpenTelemetry SDK |
| [credentials](credentials/README.md) | Re-sign JWTs, refresh opaque bearer tokens and replay HTTP Basic credentials in an independent Node app |
| [contract-testing](contract-testing/README.md) | Compare a deliberately invalid vendor capture with the clean baseline using an OpenAPI contract |
| [sqlcommenter](sqlcommenter/README.md) | which inbound request ran each SQL query, exactly, from the trace id the app writes into a SQL comment |
| [chaos](chaos/README.md) | Verify a Node storefront against API and latency requirements using recorded inventory traffic |
| [browser-journeys](browser-journeys/README.md) | Run Playwright tests with a frontend's API calls answered from a recording, or compared with it, and see which call broke a journey |
| [playwright-gates](playwright-gates/README.md) | Use an agent and the browser-journey-tests skill to turn an ordinary Playwright suite into a regression gate and a web-vitals and API-load performance gate |
| [llm-streaming](llm-streaming/README.md) | Record streamed LLM chat traffic, replay it to measure time to first token and inter-token latency, and fail the replay when a slower model server regresses them |
| [grpc](grpc/README.md) | Read recorded gRPC and protobuf bodies as Protoscope and as named JSON from the service's `.proto`, with Pub/Sub, gRPC health and OTLP calls named by the built-in schemas and gRPC error details decoded |

The reference API and traffic tools live in [shared/](../shared/README.md). The reusable baseline lives in the root [proxymock workspace](../proxymock/README.md).
