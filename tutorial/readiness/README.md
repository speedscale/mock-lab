# Measured readiness reference

The Go orders service can enable additional fixture routes with `READINESS_FIXTURE=1`. They exercise real Postgres state, idempotency, competing writes, authorization, cache expiry, bounded admission, dependency recovery, correlated logs and business audit events. Normal tutorial routes remain available. `READINESS_DEFECT=R01` through the supported requirement IDs seed corresponding behavior defects; The original order-history amplification case is retained at fixture commit `97773ac`; the repaired handler uses one aggregate query even with `APP_SLOW=1`. Reproduce the failure from that commit, then compare the repair commit against the same protected profile.

Use a Speedscale review build containing `proxymock readiness`. This adapter measures the reference service; it does not infer these contracts for arbitrary applications. The verifier, its budgets and its pinned recording must remain outside application repair permissions.

## Local setup

Start in `tutorial/go`, build the app, and create an isolated Postgres 17 database whose name begins with `readiness_`. Initialize it using `../readiness/schema.sql`, with `pg_stat_statements` enabled through `shared_preload_libraries`. The schema creates a restricted `candidate` application role and a marker that the verifier checks before resetting state. The database administrator is the independent verifier. Use fixture credentials only.

```sh
go build -o ./bin/orders .
export READINESS_CONTROL_TOKEN="$(openssl rand -hex 24)"
proxymock readiness reference-dependency --listen 127.0.0.1:18761
```

In another shell, start the app with `READINESS_FIXTURE=1`, `DATABASE_URL` set to the candidate role, `DEMO_API_URL=http://127.0.0.1:18761`, `READINESS_LOG` set to a dedicated JSONL file, and `PORT=8080`. Wait for `/ready/readyz` to return 200 before capturing approved healthy traffic.

```sh
proxymock readiness capture --test-against http://127.0.0.1:8080 --out ./proxymock/approved-readiness
```

Create a reference adapter JSON with these fields. Paths must be absolute and `pid` must identify the running executable. `appEnvironment` supplies the same settings when the verifier starts separate startup and configuration-variant processes.

```json
{
  "target": "http://127.0.0.1:8080",
  "dependency": "http://127.0.0.1:18761",
  "databaseEnv": "READINESS_DATABASE_URL",
  "controlTokenEnv": "READINESS_CONTROL_TOKEN",
  "databaseName": "readiness_reference",
  "executable": "/absolute/path/to/orders",
  "sourceDir": "/absolute/path/to/tutorial/go",
  "corpus": "/absolute/path/to/proxymock/approved-readiness",
  "appEnvironment": ["READINESS_FIXTURE=1", "DATABASE_URL=postgres://candidate:fixture-candidate@127.0.0.1:5432/readiness_reference?sslmode=disable", "DEMO_API_URL=http://127.0.0.1:18761", "READINESS_LOG=/absolute/path/to/app.jsonl"],
  "pid": 12345,
  "logPath": "/absolute/path/to/app.jsonl",
  "full": false
}
```

Set `READINESS_DATABASE_URL` to the independent verifier connection and keep the same private control token in the runner shell. Run directories must be new.

```sh
proxymock readiness run --reference ./reference.json --profile production-v1 --out ./proxymock/results/baseline --strict
proxymock readiness show --run ./proxymock/results/baseline
proxymock readiness export --run ./proxymock/results/baseline > readiness-bundle.json
proxymock web --in . --readiness-only
```

The local scope requires 23 checks. R23 is explicitly out of scope locally. R12, R16, R18, R21 and R24 are deferred everywhere in this first version. Short fixture windows do not qualify endurance, elasticity, attributed dollar cost, asynchronous ordering or rollback/migrations.

## Dev rollout scope

Build the app image from `tutorial/go` with `docker build -f ../readiness/Dockerfile`. Build a private dependency image containing the review `proxymock` executable and its `readiness reference-dependency` command. Set `APP_IMAGE` and `DEPENDENCY_IMAGE` to immutable image references, then render `dev.json` with `envsubst` and apply it with `kubectl --context dev`. The namespace is `readiness-reference`; private registries need a namespace-local pull secret. The checked-in passwords are disposable fixture values, and the controller token must be replaced with a private fixture value shared with the verifier.

The manifest supplies two app replicas, real Postgres, the controlled dependency, a separate router, a readiness probe, a pre-stop routing delay and a shutdown grace period. Forward the router, database and dependency services to loopback. Set `full: true`, `clusterNamespace: readiness-reference`, and `clusterDeployment: orders` in the adapter configuration. Set `executable` to a local copy of the exact `/candidate` bytes in the deployed image; the verifier checks those bytes in every ready app container. Full scope requires 24 checks, including actual controller replacement with accepted long-running orders, independent durable reconciliation and container resource evidence.

## Protected repair cycle

Save the baseline result's `profile` object as a frozen JSON profile before introducing a defect. The runner rejects a changed profile digest or recording. Introduce the N+1 candidate and run that frozen profile. Give the coding agent read access to the failing case and application source, with filesystem/tool write access restricted to application handlers. Keep tests, fixture behaviors, measurement code, budgets and corpus read-only. Verify the patch diff before building it.

Keep `APP_SLOW=1` during repaired-candidate verification. The patch must remove per-row SQL amplification, preserve the feature response and use the same required checks. Run a fresh output directory with `--profile frozen-profile.json --parent <failing-run-id>`. Prior failures remain retained. A changed executable or source/configuration during a run invalidates its results; missing observations and cancelled work cannot become PASS.

New readiness CI exits are 0 for a complete passing declared profile, 1 for a measured failure, 2 for incomplete/unknown required evidence and 3 for configuration or operational failure. Operational errors take precedence over failure, then incomplete evidence. `--exit-zero` is rejected. Existing replay exit behavior is unchanged.
