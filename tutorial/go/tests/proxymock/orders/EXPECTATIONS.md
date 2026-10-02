# Candidate expectation review

Review this set together before accepting suite.yaml. Pricing, validation, stored state and upstream error behavior come from the [behavior contract](../../../../contract/SPEC.md). The optional auth requirement and local performance budgets are fixture proposals requiring developer approval. The recording supplies concrete synthetic customers, project data and seeded IDs; it does not independently establish business rules.

| Request | Expected response and behavior | Evidence |
| --- | --- | --- |
| POST /orders, fixture-alice, Kubernetes quantity 2 | 201; placed order; integer unit price 1200; integer total 2400 | Contract pricing and create-order behavior |
| GET Alice's order | 200; Alice/Kubernetes/quantity 2/total 2400; matching seeded ID | Contract stored-order behavior and approved fixture |
| POST /orders, fixture-bob, Flux quantity 1 | 201; placed order; integer unit price 800; integer total 800 | Contract pricing and create-order behavior |
| GET Bob's order | 200; Bob/Flux/quantity 1/total 800; matching seeded ID | Contract stored-order behavior and approved fixture |
| GET /catalog | 200; Kubernetes/Graduated/1200, Flux/Incubating/800, Sandbox/Sandbox/500 | Local catalog fixture and contract pricing |
| GET Alice's order status | 200; Alice's ID and placed status | Contract status endpoint |
| GET /orders | 200; both distinct orders with their correct customers and totals | Contract list endpoint and stored fixture data |
| POST /orders with an empty object | 400; customer is required | Contract validation order |
| GET /orders/not-a-uuid | 404; order not found | Contract ID validation |
| GET /orders without a bearer token | 401; unauthorized | Proposed optional Go fixture auth contract |
| GET /catalog while catalog returns 503 | 502; catalog unavailable | Contract upstream error behavior |
| GET /catalog after the fault window | Healthy 200 catalog response within 10 seconds | Proposed recovery deadline plus healthy catalog fixture |

Alice's seeded ID is 2cfa6a74-eace-5f52-8354-f048465c4cfe; Bob's is b94d7236-ec3c-5fba-b32a-2eb774178728. These values preserve replay correlations under the fixture's fixed ID seed. Response comparison ignores only generated_at and created_at, while preserving IDs, customers, item quantities, names, types, ordering and totals. OpenAPI validates response types independently.

Load uses the two reads in reverse order for two seconds, at four actors in dev and eight in ci. Every response retains business assertions. Proposed budgets are P95 at most 250ms, throughput at least one response per second and zero native transaction errors, with dependency timing disabled. These are local app-against-mocks budgets, not production SLOs or real database capacity. A native delivery shortfall or exceeded request ceiling is incomplete.

Chaos changes only /v1/projects catalog calls to 503 at 100% for four seconds. It must show the selected rule, matched requests and changed downstream status, then the accepted app 502 and a healthy recovery response after removal. A matching rule without an observed effect cannot qualify.

SQL read blueprints use the normalized recorded statement location and order-ID parameters. They must return Bob's row for Bob and Alice's row for Alice regardless of arrival order. Qualification asserts complete bodies with eight actors and no missing mocks or passthrough.

Acceptance covers the complete manifest, schema, recordings, SQL tuning, faults and budgets. Changing an input or editing while reviewing requires a new revision confirmation. The checked-in suite is a candidate; no developer acceptance or release qualification is implied by local exploration results.
