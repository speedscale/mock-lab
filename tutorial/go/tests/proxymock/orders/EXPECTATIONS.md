# Candidate expectations

Review these expectations, native configs and proposed budgets through the normal repository review before using them as a CI baseline. Business behavior comes from the [existing contract](../../../../contract/SPEC.md); response shape comes from its [OpenAPI schema](../../../../contract/openapi.yaml). The recording contains synthetic customers and catalog examples. It does not independently establish business correctness.

| Case | Expected behavior | Evidence |
| --- | --- | --- |
| Create Alice's Kubernetes order, quantity 2 | 201; unit price 1200; integer total 2400 | Contract pricing and create behavior |
| Read Alice's order | Alice/Kubernetes/quantity 2/total 2400 and recorded ID | Contract stored-order behavior plus fixture |
| Create Bob's Flux order, quantity 1 | 201; unit price 800; integer total 800 | Contract pricing and create behavior |
| Read Bob's order | Bob/Flux/quantity 1/total 800 and recorded ID | Contract stored-order behavior plus fixture |
| Catalog | 200; recorded projects with contract prices | Fixture maturity and contract pricing |
| Order status and listing | 200; correct recorded orders/status/totals | Contract and fixture data |
| Empty order object | 400; customer is required | Contract validation order |
| Invalid order ID | 404; order not found | Contract ID validation |
| Catalog dependency returns 503 | App returns 502; catalog unavailable | Contract upstream error handling |
| Confirmed catalog outage | Same app returns healthy catalog and passes recovery assertions within 10 seconds of completing the outage replay, including the remaining fault window | Candidate recovery deadline and healthy fixture |

Alice's recorded ID is 2cfa6a74-eace-5f52-8354-f048465c4cfe; Bob's is b94d7236-ec3c-5fba-b32a-2eb774178728. These are captured examples; the unchanged app generates fresh random IDs on creation. The native test config ignores id only for POST responses and generated_at/created_at for both methods. GET responses retain ID, customer, quantities, names, types and totals. Replaying the recorded reads checks distinct existing rows; it does not prove that a newly created ID is correlated through a complete new journey.

Read blueprints key normalized SQL S3/S4/S7 on the order-ID parameter. Reversed reads and eight actors must still return the correct complete rows. Dynamic catalog ts and write/list parameters remain unkeyed. No live database is used for this replay, so transactional state and database capacity remain untested.

Candidate local budgets are P95 <= 250ms, throughput >= 1 response/second and zero native transaction failures, with response assertions retained and dependency timing disabled. These are app-against-mocks thresholds requiring review, not production SLOs. The unchanged APP_VERSION=v2 plant must fail body assertions and schema validation. A delayed native mock must fail the latency budget. Inactive faults or missing mocks must not be reported as a successful chaos/correctness test.

Original input covers 2 of the schema's 6 operations; expanded input covers 5. Exercise the additions and validate actual responses before reporting passed coverage. Generated, exercised and passed remain separate report claims backed by native artifacts. Authentication is outside this demo's existing contract.
