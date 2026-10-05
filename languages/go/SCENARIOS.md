# One recording, several tests

Use this existing HTTP app and its committed recording. You need Go and an initialized proxymock CLI. The app uses only the Go standard library. No Docker, database, dashboard, jq or custom runner is needed for these examples. Run commands from `languages/go`.

## Start the app with mocks

Leave this running in one terminal:

```sh
proxymock mock --in proxymock/recording --no-passthrough --mock-timing none \
  --app-health-endpoint http://localhost:8080/ --out proxymock/results/healthy \
  -- go run .
```

The recording supplies the HTTP dependency. Wait for the app to start before replaying. Stop this command with Ctrl-C when finished. Each output directory below retains native evidence; use a fresh name for another run. Existing Git ignores keep results and replay staging out of commits.

## Regression, contract and load

In a second terminal, select the four recorded read requests. Auth and order correlation are separate examples already covered by this app's README.

```sh
READS='(direction IS IN) AND (command IS GET) AND (location REGEX "^/api/(projects|categories|stats)")'
proxymock replay --in proxymock/recording --tests-filter "$READS" \
  --test-against http://localhost:8080 --rewrite-host --out proxymock/results/regression
proxymock validate --spec proxymock/applications/my-app.openapi.yaml \
  --in proxymock/results/regression
proxymock replay score proxymock/results/regression --mock-run proxymock/results/healthy -o json
proxymock replay --in proxymock/recording \
  --tests-filter '(direction IS IN) AND (location IS "/api/stats")' \
  --test-against http://localhost:8080 --rewrite-host --vus 2 --for 2s \
  --fail-if 'latency.p95>250' --fail-if 'requests.failed>0' \
  --out proxymock/results/load
```

Regression checks recorded responses; contract checks actual responses against the existing app schema. The load thresholds are candidate local budgets for the app against mocks, requiring review. Read the native score for accuracy, goals and measured mock matching; a replay exit alone does not establish full mock coverage. Resource measurements and production capacity are outside this example.

## Chaos: prove the budget catches a slow dependency

Stop the healthy mock and start the same app with a scoped latency fault:

```sh
proxymock mock --in proxymock/recording --no-passthrough --mock-timing none \
  --app-health-endpoint http://localhost:8080/ --out proxymock/results/slow-dependency \
  --chaos '(location REGEX "^/v1/projects"): latency=300ms,percent=100' -- go run .
```

Run the same load command with `--out proxymock/results/chaos`. It should exit 1 because P95 exceeds 250ms; recorded response correctness should still pass. This is an intentional budget-failure demonstration. Check the reported latency and the mock's `X-Speedscale-Chaos` rule/effect evidence before attributing it to the fault. Do not treat a missing mock or unrelated failure as success. Stop the faulted mock, restart the healthy command and rerun load to show the budget passing again. This demonstrates recovery after restart; same-process recovery and deadlines are advanced cases.

## The two prompts

“Use the small recording in languages/go to save regression, contract, bounded load and latency-fault scenarios. Reuse the app and native proxymock commands. Keep the setup to Go and proxymock, and show candidate expectations and budgets for review.”

“Read the results and app schema. Add the most useful missing error/status and request-boundary cases, then deepen the NFR checks. Run the additions and separate generated, exercised and passed coverage.”

The quality-loop skill composes the existing specialists. Save commands and native assets in the repository, so reruns need no model. Preserve accepted expectations between prompts. Use native `coverage` on the original recording and actual replay outputs; `generate <schema>` proposes cases, not accepted business outcomes. Missing dependency examples need owned capture or existing fixtures. Keep authentication, database isolation and richer resilience exercises for the app that needs them.

For a fresh small capture, use the record-traffic skill from this app directory. Point `DOWNSTREAM_URL` at the development API or the existing local reference server. Drive `/api/projects`, `/api/projects/kubernetes`, `/api/categories` and `/api/stats` through proxymock's recording port using your browser, then stop capture. Do not add a database to this HTTP app.
