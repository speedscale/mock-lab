# Contract testing

Validate a captured dependency response against its OpenAPI contract. This exercise contains five downstream RRPairs copied from the clean baseline. Two responses were deliberately modified: a category count is a string, and one Kubernetes project response omits the required maturity field.

Prerequisites: an activated proxymock CLI. No application or downstream server needs to run. From this directory:

```shell
proxymock validate --spec ../../shared/openapi.yaml --in proxymock/recording/demo-api.trafficreplay.com
```

Expect exit code 2, with three conformant pairs and two violating pairs. Compare with the clean baseline:

```shell
proxymock validate --spec ../../shared/openapi.yaml --in ../../proxymock/recording/demo-api.trafficreplay.com
```

Expect exit code 0 and five conformant pairs. Inspect the violations, then ask your agent to explain what a caller would need to handle if the vendor shipped those changes. Keep this invalid capture separate from the baseline used for mocking and replay.

This exercise only reads the committed captures; no services need cleanup.
