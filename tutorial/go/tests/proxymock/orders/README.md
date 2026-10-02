# Recording to scenarios fixture

This candidate suite exercises the Go orders app with HTTP catalog and Postgres dependencies mocked by proxymock. Four initial create/read requests preserve two distinct orders. Supplemental local capture adds catalog, listing, status, 400, 404 and auth 401 cases; the chaos fixture comes from the documented catalog-unavailable behavior.

For a new local recording, Docker and Go are required. This creates fresh Postgres with the contract schema and a local catalog, records four initial requests (ten with --improve), applies native DLP before writing traffic and checks the credential canary in encoded and decoded fields. It stops only its own processes/container and removes raw capture after verified export. It writes a separate ignored candidate; it never overwrites this fixture or an accepted suite.

~~~sh
python3 tests/proxymock/orders/capture.py
python3 tests/proxymock/orders/capture.py --improve
~~~

The sanitized directory and inventory give the agent recording paths, original recorded dependency addresses and canary hashes for a new suite. Review any remaining project-specific PII rules locally before sharing the export.

Use a proxymock build with the saved-suite command. From tutorial/go:

~~~sh
go build -o .suite-bin/orders .
export TUTORIAL_AUTH_TOKEN="$(openssl rand -hex 24)"
proxymock suite validate tests/proxymock/orders/suite.yaml
proxymock suite explore tests/proxymock/orders/suite.yaml --profile dev
~~~

Exploration deliberately exits 2 even when its cases pass. Review the response fixtures against SPEC.md, the optional-auth contract, SQL parameter keys, fault/recovery behavior and the proposed 250ms P95 / one response per second / zero-error budgets together. After review, a developer accepts that exact revision in a terminal:

~~~sh
proxymock suite accept tests/proxymock/orders/suite.yaml --reviewer developer
proxymock suite run tests/proxymock/orders/suite.yaml --profile ci
~~~

The candidate has no accepted baseline checked in. CI must use an unchanged developer-accepted revision and a fresh runtime token; it must never accept a suite automatically. Each case starts fresh app/mock processes, so replay does not need a live catalog, Postgres, a model or an agent. The fixed clock and ID seed preserve the captured correlations. SQL SELECTs are keyed by order ID using normalized recorded locations. The load fixture reverses the original read order and asserts complete response bodies at eight actors.

Results contain measured workload, native goals, fault effect and recovery evidence. Coverage pins six OpenAPI operations and keeps original, generated, exercised and passed counts separate. The healthy fixture should progress from 2/6 original operations to 5/6 passed operations and exercise 400, 401, 404 and 502 responses. Healthz remains uncovered.

Run the qualification script to prove two parallel suites, eight actors, six deliberate defects, and interruption of one run while the other continues:

~~~sh
PROXYMOCK_BIN=/absolute/path/to/proxymock python3 tests/proxymock/orders/prove.py
~~~

The script invokes the native suite CLI for every verdict. It never accepts expectations and always treats its runs as exploration. Wrong pricing, response types, excessive latency and failed recovery must fail; missing mocks and an inactive fault must be incomplete. Its temporary mutations are removed, and metadata-only qualification remains under ignored proxymock/suite-proof/. Python 3 and Go are required.

These budgets measure the app against mocks with dependency timing disabled. They do not measure database or production capacity. Fresh-worker reliability, timed two-prompt authoring, owned real-database profiles and container resource metrics still need qualification before release.
