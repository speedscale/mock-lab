# Reusable baseline workspace

This is a standard proxymock workspace. Its recording has eight inbound language-app calls under `recording/localhost/` and five outbound dependency calls under `recording/demo-api.trafficreplay.com/`. The Markdown files are RRPair traffic data.

The workspace keeps the recording together with its companion documents: `applications/my-app.openapi.yaml` describes the recorded app workload, `blueprints/mocklab-smart-replace.json` chains fresh access tokens and order IDs during replay, and `testconfigs/schema-coverage.json` defines coverage goals. Keep these standard directory names so proxymock can discover the documents from `--in proxymock/recording`.

Run these commands from the repository root. Activate proxymock first with `proxymock init --api-key <key>`.

## Mock and replay offline

Start the Go app using the committed downstream recording:

```shell
proxymock mock --in proxymock/recording -- sh -c 'cd languages/go && go run .'
```

In a second terminal, replay the inbound requests:

```shell
proxymock replay --in proxymock/recording --test-against http://localhost:8080
```

The blueprint updates the token and order ID for the new run. Generated results belong in `proxymock/results/` and are ignored by git.

## Inspect and validate the recording

```shell
proxymock coverage --in proxymock/recording
proxymock validate --spec shared/openapi.yaml --in proxymock/recording/demo-api.trafficreplay.com
```

The downstream validation should report five conformant pairs. Coverage describes the inbound app contract; the recording covers the happy path and does not include every error response declared by that contract. The `schema-coverage` test configuration requires full operation and status coverage, so its status-coverage goal exposes those missing cases.

Each language also has its own complete workspace beside its app. Follow that language's README to work with its runtime-specific capture. The [contract-testing lab](../labs/contract-testing/README.md) holds the deliberately invalid vendor capture.
