# Credential replay lab

This independent lab gives proxymock traffic for three credential classes: signed JWT, HTTP Basic and opaque bearer. It has a small Node app, built-in crypto and a nine-request recording. Node 24+ (or 22.21+) and initialized proxymock v2.5.1133 or newer are sufficient. From your repository root, run `cd labs/credentials`. Run every command below from this lab directory. These routes are entirely local; they need no Go, npm packages, Docker, database or live downstream.

| Flow | Demo users | Credential |
| --- | --- | --- |
| POST /auth/login then GET /api/profile | alice, bob | HS256 JWT with subject and expiry |
| GET /api/account | acme:acme-secret, globex:globex-secret | HTTP Basic |
| POST /oauth/token then GET /api/orders/missing | One opaque session | Fresh random bearer; authenticated missing-order fixture returns 404 |
| GET /api/account with not-a-demo-user: | Invalid user, empty password | Must return 401 |

The signing key is the public fixture value mock-lab-demo-signing-key. Login accepts a nonempty demo username without a password. These are synthetic credentials for a local exercise, not a production login implementation. No real user credentials belong in this recording.

## Replay the committed example

One command starts a fresh Node app, replays the recording and stops the app:

```sh
proxymock replay --in proxymock/recording \
  --test-against http://localhost:8080 --rewrite-host \
  --test-config credential-replay --require-blueprint credential-replay \
  --out proxymock/results/credentials -- node index.js
proxymock replay score proxymock/results/credentials -o json
proxymock validate --spec proxymock/applications/my-app.openapi.yaml \
  --in proxymock/results/credentials
```

Expect nine matched responses and passing assertion goals, including the intended 404 and 401. The credential-replay blueprint re-signs the two profile JWTs with the public demo key, refreshing their expiry. The same blueprint refreshes the opaque token from its login response using native smart replacement. Basic credentials are the fixed synthetic set. The test config ignores the generated access_token response field while checking status, stable body fields and schema; HTTP tests separately verify issued JWTs. The unknown-user request is a regression test for accepting an empty password.

Results stay in ignored proxymock/results. Use a fresh output directory for another run. This recording has no dependency calls, so mock match rate is not a metric for this exercise. Use [the Node recording-to-scenarios guide](../../languages/node/SCENARIOS.md) for dependency mocks, load and chaos.

## Make a fresh credential capture

Start recording in one terminal:

```sh
proxymock record --app-port 8080 --out proxymock/recorded-credentials -- node index.js
```

In a second terminal, capture each JWT subject and Basic account:

```sh
for user in alice bob; do
  token=$(curl --fail --silent --show-error -H 'Content-Type: application/json' \
    -d "{\"username\":\"$user\"}" http://localhost:4143/auth/login \
    | node -p 'JSON.parse(require("node:fs").readFileSync(0, "utf8")).access_token')
  curl --fail -H "Authorization: Bearer $token" http://localhost:4143/api/profile
done
curl --fail -u acme:acme-secret http://localhost:4143/api/account
curl --fail -u globex:globex-secret http://localhost:4143/api/account
```

Stop capture with Ctrl-C, inspect the data, and use --in proxymock/recorded-credentials with a fresh output directory in the replay command. These six requests produce a smaller JWT/Basic example; the committed nine-request fixture also covers the opaque bearer and unknown-user regression. To view the committed sessions, run `proxymock web --in proxymock/recording` from this lab directory. Credential replacement and re-signing are existing product features; no new runner or CLI is introduced.

## Check auth behavior

```sh
npm test
```

The built-in Node HTTP tests cover both subjects, missing/tampered/expired/malformed JWTs, invalid JWT headers or claims, bad login input, both Basic users, wrong passwords, unknown users with empty passwords and the opaque flow. A separate credential-lab CI job runs these HTTP tests. The lab has its own schema and proxymock workspace. The built-in language demos remain independent.
