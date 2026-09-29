# Mock a dependency called during startup

This lab reproduces a service that calls a dependency before it starts listening. The committed RRPair records `GET /api/v1/buckets/demo/values?watch=true&stateRevision=42`. The service now calls the same endpoint with `watch=true` and no `stateRevision`. Without a transform, `proxymock mock --no-passthrough` returns a 404 because the recorded signature includes `http:queryparams:stateRevision`. The service cannot start.

The active [blueprint](proxymock/blueprints/startup-query.json) uses the `empty` extractor and `delete_sig` to remove only `http:queryparams:stateRevision` from the recorded mock signature. It keeps `watch=true`, the method, host, and path as match conditions. The backend is not running during verification, so a successful startup proves proxymock served the dependency response.

## Run the proof

Requirements: Go 1.23 or newer, `curl`, and an initialized proxymock CLI. Ports 4140 and 8080 must be free. Run from this directory:

```shell
make verify
```

The script runs the same recording twice. Its baseline copy has no blueprint and must fail startup with `NO_MATCH` and 404. The second run loads the blueprint and must return `ready` from the service's `/healthz` endpoint. Both runs use `--no-passthrough`, so neither can call the backend. Logs are under `.run/`.

## Inspect or change the rule

The [RRPair](proxymock/recording/localhost/2026-09-29_19-05-20.558013Z.md) shows the two captured query keys under `SIGNATURE`. The live request still has `watch=true`, so the blueprint deletes only `http:queryparams:stateRevision`. For a different recording, scope the filter to the dependency endpoint and delete the exact signature keys that are absent from the live request. Keep any stable key that selects which mock should answer.

`store_sig` adds a key to the signature; its `discard` setting does not remove one. A query parameter extractor also cannot extract a field that is absent from the live request. For this missing-field case, use `empty` with `delete_sig` and the full signature key. `http_queryparam` is the canonical extractor name when a query value needs to be read or changed.

## Recreate the recording

The repository includes a small backend only to regenerate the RRPair. Start it in one terminal:

```shell
make build
./bin/backend
```

In another terminal, run proxymock from this lab directory and stop it after the startup call appears:

```shell
STARTUP_QUERY='watch=true&stateRevision=42' proxymock record --out ./proxymock/recording -- ./bin/service
```

Stop the backend before running `make verify`. The recording is synthetic and contains no customer traffic.
