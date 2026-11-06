# Playwright gates lab

Take a team's ordinary Playwright suite and turn it into two gates with a coding agent and the [`browser-journey-tests`](https://github.com/speedscale/skills/tree/main/skills/browser-journey-tests) skill:

- **Regression:** every journey passes, with the frontend's API calls answered from a recording or sent to the real API.
- **Performance:** web-vitals budgets on the same journeys, plus a load test of the API built from the traffic the journeys generate.

The app is a small CNCF project explorer: an overview, a searchable project list, project detail pages with a **Track project** button, and a categories page. The suite in `tests/` is what a team might have before the skill ports it, and `journeys/` is what came out after.

| Question | Where the lab answers it |
| --- | --- |
| What stops a normal Playwright suite from running as a replay? | [Run the skill](#1-run-the-skill) |
| Does the frontend still work, with no API running? | [Regression gate](#3-regression-gate) |
| Every test passes. Is it still fast? | [Performance gate, Tier A](#4-performance-gate-tier-a-what-users-feel) |
| How does the API hold up under the traffic those pages create? | [Performance gate, Tier B](#5-performance-gate-tier-b-the-api-under-load) |

The docs cover every flag and setting: [Browser Journeys](https://docs.speedscale.com/guides/browser-journeys/). The [browser journeys lab](../browser-journeys/README.md) covers running journeys in Kubernetes and reading the report.

## What is here

- `app/site/index.html` is the frontend, served by `app/serve-site.js` on port 3000. `SITE_BUG=search` serves a version whose search box sends `?query=` instead of `?q=`, so search silently stops filtering.
- `app/api/server.js` is the API on `http://api.localtest.me:8082`. It serves the CNCF dataset the [shared reference server](../../shared/README.md) uses. `LATENCY_MS=800` adds 800 ms to every response.
- `tests/` is the team's suite before the port. It has a `playwright.config.ts` with `baseURL` from an env var and a `webServer`, plus a Firefox project. It also has an absolute URL, an env var read in a spec, a helper that imports a file from outside the directory, a fixed wait, and a test that writes.
- `journeys/` is the skill's output:
  - `read-only/`: the four ported journeys, plus `categories.spec.ts`, which the skill wrote for a route the suite never covered. `_support/` has a guard that fails any journey that writes.
  - `writes/`: the half of the detail test that tracks a project. It runs only where writes are safe.
  - `perf/`: the pages whose speed matters, each registered five times so the p95 has samples.
- `proxymock/recording/` holds the API calls the journeys make, recorded headless with `make record`.
- `proxymock/api-recording/` holds the API's inbound traffic recorded while the journeys ran, which is the load-test workload.
- `proxymock/testconfigs/` holds the two gates: `playwright-gates-regression` and `playwright-gates-perf`.

`api.localtest.me` is a public DNS name that resolves to `127.0.0.1`, so the API has its own host with no `/etc/hosts` edit. If your network blocks that, add `127.0.0.1 api.localtest.me` to `/etc/hosts`.

## Before you start

You need Node 22 or newer and make. You also need [proxymock](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-cli/) newer than v2.5.1337, with local browser goal evaluation. On older builds the goals print `NOT EVALUATED`, and no performance budget can fail. Initialize it once with `proxymock init --api-key <key>`; a free key is at [app.speedscale.com/signup](https://app.speedscale.com/signup).

To run the skill yourself, you need a coding agent with the Speedscale skills. `proxymock mcp install` adds them to Claude Code and the other supported agents.

From the repository root:

```bash
cd labs/playwright-gates
```

```bash
make install
```

This installs `@playwright/test` and Chromium in this directory. The version is pinned to the one in the `generator-browser` image, so the same journeys run in a cluster.

## 1. Run the skill

The team's suite passes as it is:

```bash
make team-tests
```

```text
  ✓  2 [chromium] › tests/overview.spec.ts:4:5 › overview counts projects by maturity (397ms)
  ✓  1 [chromium] › tests/project-detail.spec.ts:3:5 › track a project from its detail page (418ms)
  ✓  3 [chromium] › tests/projects.spec.ts:5:5 › search narrows the project list (710ms)
  ✓  4 [chromium] › tests/projects.spec.ts:13:5 › maturity filter shows only sandbox projects (156ms)

  4 passed (1.8s)
```

To redo the port, move `journeys/` and the two recordings aside, then ask your agent:

```text
/browser-journey-tests labs/playwright-gates --target http://localhost:3000 --both
Writes are safe on this machine only. There is no sign-in.
```

The skill starts with an inventory of the suite. Its script reports what the runner will drop:

```text
== Playwright configs (ignored by the runner; settings below must move into specs or the test config)
tests/playwright.config.ts
- baseURL (comes from --test-against instead)
    9:    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',
- webServer (not started; start the app yourself)
    14:  webServer: [
- use options to carry into specs with test.use
    10:    testIdAttribute: 'data-test',
- non-Chromium projects (the runner is Chromium only)
    20:    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },

== Portability findings in specs and their helpers
- absolute URLs in navigation (use paths so --test-against applies)
    tests/overview.spec.ts:5:  await page.goto('http://localhost:3000/#/');
- process.env reads (nothing sets them in a cluster run)
    tests/projects.spec.ts:3:const term = process.env.SEARCH_TERM ?? 'prom';
- imports that leave the directory (check they stay inside the journeys dir)
    tests/helpers/data.ts:2:import projects from '../../../../shared/server/data/projects.json';
- fixed waits (flaky under load and in perf runs)
    tests/projects.spec.ts:8:  await page.waitForTimeout(500); // the search box debounces for 300ms
```

The script can't see that `project-detail.spec.ts` writes. Reading the spec does, so the agent split it.

## 2. What the port changed

| In `tests/` | In `journeys/` | Why |
| --- | --- | --- |
| `baseURL` and `webServer` in the config | Relative `page.goto('/#/projects')`; you start the app | The runner writes its own config and sets `baseURL` from `--test-against` |
| `testIdAttribute` in the config | `test.use({ testIdAttribute: 'data-test' })` in each spec | Config `use` options are dropped |
| Chromium and Firefox projects | Chromium | The runner runs Chromium only |
| `process.env.SEARCH_TERM` | A constant in `_support/expected.ts` | Nothing sets env vars in a cluster |
| `import ... from '../../../../shared/...json'` | Values copied into `_support/expected.ts` | Only the journeys directory ships to a cluster |
| `waitForTimeout(500)` | `await expect(status).toHaveText('1 project')` | A sleep lands in every performance number |
| Detail test clicks **Track project** | Read-only half in `read-only/`, the click in `writes/` | Read-only journeys must be safe on shared environments |
| No test for `#/categories` | `read-only/categories.spec.ts` | Built from the router |

`read-only/_support/guards.ts` enforces read-only rather than trusting it: a non-GET call to `/v1/` is aborted and fails the journey that made it.

Each directory then ran three times in a row with no failures before it joined a gate. The runner has no retries, so a flaky journey fails the gate.

## 3. Regression gate

The recording is made headless: proxymock records through its outbound proxy while plain Playwright runs the journeys once. Start the frontend and API, then record (you can skip this; the committed recording is the result):

```bash
make site
```

```bash
make api
```

```bash
make record RECORDING=proxymock/my-recording
```

Now stop the API, so nothing can reach it, and answer the frontend's calls from the recording:

```bash
make mock
```

```bash
make regression
```

```text
  ✓ categories lists every category with its project count (categories.spec.ts:6) 328ms
  ✓ overview counts projects by maturity (overview.spec.ts:6) 219ms
  ✓ project detail shows the project facts (project-detail.spec.ts:7) 249ms
  ✓ search narrows the project list (projects.spec.ts:6) 1.006s
  ✓ maturity filter shows only sandbox projects (projects.spec.ts:21) 215ms

Browser journeys: 5 passed, 0 failed, 0 skipped

TEST CONFIG GOALS (playwright-gates-regression)
 PASS browserJourneyPassPct >= 100 - observed 100
 PASS failedVUsers <= 0 - observed 0 (applied to every report by the analyzer)
Goal verdict: PASS
```

Now ship the search bug. Stop `make site` and start the broken frontend:

```bash
make site-buggy
```

```bash
make regression
```

The gate fails, exits 1 and names the call:

```text
  ✗ search narrows the project list (projects.spec.ts:6) 5.279s
      Error: expect(locator).toHaveText(expected) failed
      not in the recording: GET http://api.localtest.me:8082/v1/projects?query=prom

Browser journeys: 4 passed, 1 failed, 0 skipped

 FAIL browserJourneyPassPct >= 100 - observed 80
Goal verdict: FAIL
```

`proxymock/results/regression/browser-journey-results.json` credits the miss to the step `Fill "prom" getByLabel('Search projects')`.

To run against the real API and compare its answers with the recording, restore the frontend and use `make api` and `make mock-real` in place of `make mock`. The same `make regression` passes. `make regression-writes` runs the write journey; keep it on your own machine.

## 4. Performance gate, Tier A: what users feel

With `make site`, `make api` and `make mock-real` running:

```bash
make perf
```

```text
Browser journeys: 15 passed, 0 failed, 0 skipped
Web vitals (p95 across journeys): LCP 72ms, FCP 60ms, TTFB 11.9ms, CLS 0.02

TEST CONFIG GOALS (playwright-gates-perf)
 PASS browserJourneyPassPct >= 100 - observed 100
 PASS browserLcpP95 <= 250 - observed 72
 PASS browserFcpP95 <= 200 - observed 60
 PASS browserTtfbP95 <= 100 - observed 11.9
 PASS browserClsP95 <= 0.1 - observed 0.02
Goal verdict: PASS
```

The budgets came from three baseline runs (LCP p95 72 to 84 ms), set above the worst run with room for jitter. Now slow the API down. Stop `make api` and start:

```bash
make api-slow
```

```bash
make perf
```

```text
Browser journeys: 15 passed, 0 failed, 0 skipped
Web vitals (p95 across journeys): LCP 868ms, FCP 92ms, TTFB 7.1ms, CLS 0.02

 FAIL browserLcpP95 <= 250 - observed 868
Goal verdict: FAIL
```

Every journey still passes, so a pass/fail suite would stay green. LCP moved and TTFB did not: the HTML is as fast as before, but the content waits on the API.

## 5. Performance gate, Tier B: the API under load

The browser's captured calls are outbound, and a load replay sends inbound requests, so the load-test workload comes from the API's side. `make record-api` starts the API under `proxymock record`, points the frontend at the recording port, runs the journeys, and stops. Stop everything else first:

```bash
make record-api API_RECORDING=proxymock/my-api-recording
```

```text
recorded in proxymock/my-api-recording:
      1 GET http://api.localtest.me:4143/v1/categories
     17 GET http://api.localtest.me:4143/v1/projects
      1 GET http://api.localtest.me:4143/v1/projects/envoy
      5 GET http://api.localtest.me:4143/v1/projects/kubernetes
```

Then replay it at the API with 8 virtual users for 20 seconds, gated on p95 latency and failures:

```bash
make api
```

```bash
make load
```

```text
│ TOTAL                   │        │ 78654 │     1.87 ms │ 1.68 ms │ 2.53 ms │ 3.99 ms │ 7.16 ms │      0 │                   0% │ 3932.27      │
 ✔ passed eval "latency.p95 > 50.00" - observed latency.p95 was 4.00
 ✔ passed eval "requests.failed != 0.00" - observed requests.failed was 0.00
```

proxymock also reports this run as `HARNESS-BOUND`: the generator used more CPU than the API, so 3,900 requests per second is a floor, not the API's ceiling. Against `make api-slow` the same command fails with `failed eval "latency.p95 > 50.00" - observed latency.p95 was 807.00`.

## Other targets

The same journeys and configs run anywhere the frontend is reachable:

- **A hosted test environment:** with `make mock-real` running, `make regression FRONTEND=https://<staging-host>`. Use read-only journeys only, and point the recording at the APIs that environment calls.
- **A Kubernetes cluster:** `proxymock cluster replay start --in proxymock/recording --browser journeys/read-only --target <frontend URL reachable from the pod> --test-config playwright-gates-regression --wait`. The [browser journeys lab](../browser-journeys/README.md#5-run-it-in-a-cluster) walks through a cluster run end to end.

## Check every step

```bash
make verify-local
```

This runs every step above with its own servers, including the deliberate failures, and checks each exit code and the lines that matter. It needs ports 3000, 4140, 4143 and 8082 free and takes about a minute and a half. Then:

```bash
make clean
```

## If something looks wrong

- **The performance goals print `NOT EVALUATED`.** Your proxymock is v2.5.1337 or older, from before local browser goal evaluation. A failed journey still fails the run through `failedVUsers`, but no budget can. Upgrade proxymock.
- **A journey fails on a page that says `API call failed: ... answered 404`.** With `make mock`, a call the recording doesn't have gets a 404. The failed journey names the call. Record it, or find out why the frontend started making it.
- **`make record-api` hangs waiting for a port.** Something else is on 3000, 4143 or 8082. Stop the other terminals first.
- **`make install` fails to download Chromium.** Playwright downloads it from its CDN; set `HTTPS_PROXY` if you are behind a proxy.
