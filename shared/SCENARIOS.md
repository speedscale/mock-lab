# One recording, several tests

Use any of the ten built-in language apps to turn a small capture into regression, contract, bounded load and chaos scenarios. Each workspace has the same app schema, blueprint, test config and equivalent baseline traffic. You need that app's runtime and initialized proxymock v2.5.1133 or newer. Docker, a database and the dashboard are unnecessary.

## Choose a language

Enter one app directory from the repository root. Read its README for runtime prerequisites and proxy/TLS setup, then set the Bash or Zsh array below. Run every remaining command from that app directory. Set the array in both terminals; it is a shell variable, not a new runner.

| App directory | App command | Build first |
| --- | --- | --- |
| [languages/go](../languages/go/README.md) | `APP=(go run .)` | None |
| [languages/node](../languages/node/README.md) | `APP=(node index.js)` | None |
| [languages/python](../languages/python/README.md) | `APP=(python3 app.py)` | None |
| [languages/java](../languages/java/README.md) | `APP=(java App.java)` | None |
| [languages/kotlin](../languages/kotlin/README.md) | `APP=(java -jar app.jar)` | `kotlinc App.kt -include-runtime -d app.jar` |
| [languages/ruby](../languages/ruby/README.md) | `APP=(ruby app.rb)` | None |
| [languages/dotnet](../languages/dotnet/README.md) | `APP=(dotnet run)` | None |
| [languages/cpp](../languages/cpp/README.md) | `APP=(./app)` | `c++ -std=c++17 main.cpp -o app -lcurl` |
| [languages/php](../languages/php/README.md) | `APP=(php app.php)` | None |
| [languages/rust](../languages/rust/README.md) | `APP=(./target/release/app)` | `cargo build --release` |

For example, Node needs no package installation:

```sh
cd languages/node
APP=(node index.js)
export NODE_USE_ENV_PROXY=1
export NODE_EXTRA_CA_CERTS="$HOME/.speedscale/certs/tls.crt"
```

Java and Kotlin need the JVM proxy and truststore settings in their READMEs. Other apps include their runtime-specific proxy and CA handling. Keep that setup in the terminals that start record or mock. All apps use port 8080; run one example at a time.

## Start the app with mocks

Leave this running in one terminal:

```sh
proxymock mock --in proxymock/recording --no-passthrough --mock-timing none \
  --app-health-endpoint http://localhost:8080/ --out proxymock/results/healthy \
  -- "${APP[@]}"
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
  --chaos '(location REGEX "^/v1/projects"): latency=300ms,percent=100' -- "${APP[@]}"
```

Run the same load command with `--out proxymock/results/chaos`. It should exit 1 because P95 exceeds 250ms; recorded response correctness should still pass. This is an intentional budget-failure demonstration. Check the reported latency and the mock's `X-Speedscale-Chaos` rule/effect evidence before attributing it to the fault. Do not treat a missing mock or unrelated failure as success. Stop the faulted mock, restart the healthy command and rerun load to show the budget passing again. This demonstrates recovery after restart; same-process recovery and deadlines are advanced cases.

## The two prompts

“Use the small recording in this app directory to save regression, contract, bounded load and latency-fault scenarios. Reuse this app and native proxymock commands from shared/SCENARIOS.md. Keep the setup to this runtime and proxymock, and show candidate expectations and budgets for review.”

“Read the results and app schema. Add the most useful missing error/status and request-boundary cases, then deepen the NFR checks. Run the additions and separate generated, exercised and passed coverage.”

The quality-loop skill composes the existing specialists. Save commands and native assets in the repository, so reruns need no model. Preserve accepted expectations between prompts. Use native `coverage` on the original recording and actual replay outputs; `generate <schema>` proposes cases, not accepted business outcomes. Missing dependency examples need owned capture or existing fixtures. Keep authentication, database isolation and richer resilience exercises for the app that needs them.

## Record a small capture

The committed recording lets the scenarios run offline. For a fresh capture, stop any running mock, keep your runtime setup, and start:

```sh
proxymock record --app-port 8080 --out proxymock/recorded-scenarios -- "${APP[@]}"
```

The unchanged app calls the dedicated public mock-lab reference API, so this capture needs internet access. For your own application, use an owned development target. In a second terminal, send four reads through the recording port (4143):

```sh
curl --fail http://localhost:4143/api/projects
curl --fail http://localhost:4143/api/projects/kubernetes
curl --fail http://localhost:4143/api/categories
curl --fail http://localhost:4143/api/stats
```

Stop capture with Ctrl-C, inspect the recording for sensitive data, then replace `--in proxymock/recording` with `--in proxymock/recorded-scenarios` in the commands above. The existing app schema is unchanged. For the first prompt, point the agent at that capture and ask it to use your chosen language app. The optional [dashboard](README.md) requires Go; the curl commands above do not.
