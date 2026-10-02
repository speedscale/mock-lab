# Recording to scenarios

This fixture uses the unchanged Go orders service, native proxymock commands and the [existing behavior contract](../../../../contract/SPEC.md). HTTP catalog and Postgres dependencies are mocked. Four initial create/read requests cover two operations; nine expanded requests cover five of the six OpenAPI operations plus documented 400 and 404 responses. The chaos case adds the documented catalog-unavailable 502 response.

From `tutorial/go`, with Go, proxymock, curl and jq installed:

```sh
bash tests/proxymock/orders/run.sh
```

The fixture-specific CI recipe runs native regression assertions, schema validation, eight-actor load, a bounded catalog outage and healthy recovery on the same app. It preserves native failure exits and checks native measured mock matching and applied fault evidence. It saves separate original/generated/exercised coverage JSON and native verdicts/goals under ignored `proxymock/results/`. It does not define a new suite format or implement a scorer. No live database, catalog or AI provider is needed for reruns.

Review [candidate expectations](EXPECTATIONS.md), configs, schema and budgets through the normal repository review before enabling a CI baseline. The schema is referenced directly from the contract, not copied or weakened. POST assertions ignore the newly generated ID; GET assertions retain the recorded ID and complete business values. This checks recorded rows, not a new transaction's persistence. Authentication is outside the demo contract.

Each run owns its app/mock processes and result directory. Allocate a separate five-port block per parallel worker, or use existing container/job isolation:

```sh
PORT_BASE=18080 bash tests/proxymock/orders/run.sh
PORT_BASE=18180 bash tests/proxymock/orders/run.sh
```

These two commands can run concurrently. The recipe's trap stops only its own mock; native proxymock manages the wrapped app. Git inputs stay unchanged; the recipe copies them into its result directory because native replay writes .replay staging beside its input. SQL read blueprints key the order-ID parameter using normalized statement locations. Load reads Bob then Alice, reversing their captured arrival order. Native responder metrics use a shared port 4145, so use container/job isolation for independently scraped resource measurements. Budgets measure the app against mocks with dependency timing disabled; they are candidate local thresholds, not production SLOs or database capacity.

The existing type-regression plant must make the recipe fail:

```sh
APP_VERSION=v2 PORT_BASE=18280 bash tests/proxymock/orders/run.sh
```

For a latency-budget defect, use a separate local run with the native mock's `--chaos '(location REGEX "^/v1/projects"): latency=300ms,percent=100'`, then replay the healthy catalog request from recovery/ with budgets.json. This delays a dependency that the selected request actually calls. Keep the normal recipe unchanged. An inactive fault, missing mock data or absent native evidence must fail qualification, not establish a baseline. Resource limits, real-database behavior, broader faults and fresh-worker reliability are untested here.

## Two prompts

“Use this small recording and the existing contract to create regression, contract, bounded load and chaos scenarios. Mock dependencies, reuse this repo's test setup, save native commands/configs, and show expectations for review.”

“Read the results and schema. Add the most important missing operations, documented error statuses, request boundaries and NFR/recovery cases. Run the additions and report generated, exercised and passed coverage separately.”

Use the managed quality-loop skill to compose the specialists. Preserve accepted expectations across prompts. Do not invent business outcomes from a schema. Native `generate <schema>` supplies candidate RRPairs; additional dependency examples require owned supplemental capture or reviewed fixtures. The initial recording is preserved in original/; the expanded recording provides sanitized dependency examples and blueprints. No provider sees raw capture.

For new capture, use the existing `proxymock record` workflow from this app directory with owned Postgres and the existing traffic driver (`TRAFFIC_FILE` can select a smaller JSON workload). Reuse the contract's setup and native mappings; apply and verify local DLP before sharing or committing the recording. Do not use the hosted catalog for load or chaos. Property tests follow through an existing framework once accepted invariants and repeatable state are available.
