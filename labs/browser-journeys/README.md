# Browser journeys lab

Run ordinary Playwright tests as a replay: on your machine with `proxymock replay --browser`, then in a cluster with `proxymock cluster replay start --browser`. The frontend's API calls are answered from a recording, or sent to the real API and compared with it. When a journey fails, the result names the call behind the failure.

| Question | Where the lab answers it |
| --- | --- |
| Can the frontend run with no API tier deployed? | [Replay on your machine](#2-replay-on-your-machine), with the API stopped |
| Did the frontend break, or something behind it? | [Two failures that look alike](#3-two-failures-that-look-alike) |
| Did a backend change break the frontend? | [Compare with the real API](#4-compare-with-the-real-api) |
| Does it work in Kubernetes on released images? | [Run it in a cluster](#5-run-it-in-a-cluster) |
| What does the report show? | [Read the report](#6-read-the-report) |

The docs cover every flag and setting: [Browser Journeys](https://docs.speedscale.com/guides/browser-journeys/).

## What is here

- `app/site/index.html` is the frontend, a one-page shop. Its **Load items** and **Next page** buttons call `http://api.localtest.me:8081/items` with a custom header, so the browser sends a CORS preflight first, as a real cross-origin frontend does.
- `app/api/server.js` is the API. Setting `ITEM_FIELD=title` renames a response field, which is the backend change in step 4.
- `journeys/` holds a journey that passes. `journeys-failing/` adds two that fail on purpose.
- `proxymock/recording/` is a committed recording made with `make record`: the API calls behind one click on **Load items**, and the journey Playwright wrote for it.
- `config/` holds the test configs, with the journey goals, and the Kubernetes manifests.

`api.localtest.me` is a public DNS name that resolves to `127.0.0.1`, so the API has its own host with no `/etc/hosts` edit. If your network blocks that, for example through DNS rebinding protection, add `127.0.0.1 api.localtest.me` to `/etc/hosts`.

## Before you start

You need Node 22 or newer and make, plus [proxymock](https://docs.speedscale.com/proxymock/getting-started/quickstart/quickstart-cli/) v2.5.1274 or newer, initialized with `proxymock init --api-key <key>`. A free key is at [app.speedscale.com/signup](https://app.speedscale.com/signup). Steps 1 to 4 need nothing else.

Steps 5 and 6 add minikube, a container runtime with about 6 GB free, kubectl and helm.

From the repository root:

```bash
cd labs/browser-journeys
```

```bash
make install
```

This installs `@playwright/test` and Chromium in this directory, where proxymock finds them. The version is pinned to the one in the `generator-browser` image.

## 1. Record a journey

You can skip this step, because the committed recording is the result of it. To make your own, start the frontend and the API in two terminals:

```bash
make site
```

```bash
make api
```

In a third terminal:

```bash
make record
```

This runs `proxymock record --browser http://localhost:3000`, which opens Chromium with Playwright's code generator. Click **Load items**, then close the window. Don't click **Next page**: step 3 needs a call the recording does not have.

proxymock writes the API calls under `proxymock/my-recording/` and the journey under `proxymock/my-recording/journeys/`. The script also removes the traffic Chromium sends on its own account, such as its update and sign-in checks. It would otherwise sit in the recording beside the shop's calls.

The generated spec is a starting point: it clicks, but it asserts nothing. `journeys/items.spec.ts` is the same click with a named step and an expectation.

To use your recording in the steps below, add `RECORDING=proxymock/my-recording` to the make commands. Stop the API before step 2.

## 2. Replay on your machine

The API stays stopped for this step, and `api.localtest.me:8081` has nothing listening. Start the frontend and the mock server in two terminals:

```bash
make site
```

```bash
make mock
```

`make mock` runs `proxymock mock --in proxymock/recording --no-passthrough`, so a call the recording cannot answer gets a 404 instead of going to the real host. In a third terminal:

```bash
make replay
```

This runs:

```bash
proxymock replay --in proxymock/recording --browser journeys \
  --test-against http://localhost:3000 --browser-proxy http://localhost:4140 \
  --out proxymock/results/journeys
```

The journey passes with no API running, and the command exits 0:

```text
  ✓ shopper loads the item list (items.spec.ts:3) 178ms

Browser journeys: 1 passed, 0 failed, 0 skipped
Web vitals (p95 across journeys): LCP 20ms, FCP 20ms, TTFB 3.3ms, CLS 0
```

`--test-against` is the frontend, and relative URLs in a spec resolve against it. `--browser-proxy` sends the browser's other traffic through the mock server.

## 3. Two failures that look alike

`journeys-failing/` keeps the passing journey and adds two that fail. With the frontend and `make mock` still running:

```bash
make replay-failing
```

The command exits 1:

```text
  ✓ shopper loads the item list (items.spec.ts:3) 164ms
  ✗ shopper sees a checkout button (checkout.spec.ts:5) 3.164s
      Error: expect(locator).toBeVisible() failed
  ✗ shopper pages through the items (next-page.spec.ts:4) 3.151s
      Error: expect(locator).toHaveText(expected) failed
      not in the recording: GET http://api.localtest.me:8081/items?page=2

Browser journeys: 1 passed, 2 failed, 0 skipped
```

Both are red, and a plain Playwright run would stop there. Here they read differently:

- **shopper sees a checkout button** has no call listed under it. Every call it made was answered, and the page has no Checkout button. That failure is the frontend's.
- **shopper pages through the items** names `GET .../items?page=2`, which was not in the recording. Record that call and the journey passes, or find out why the frontend started making it.

Open a failed journey's trace with the path the command prints:

```bash
npx playwright show-trace <test-results>/<journey>/trace.zip
```

## 4. Compare with the real API

So far the recording answered. Now send the same journey to the real API and compare the answers with the recording. Stop `make mock`, then start the API and the mock server in observe mode:

```bash
make api
```

```bash
make mock-real
```

`make mock-real` runs `proxymock mock --in proxymock/recording --observe-real-apis`. Run the journey, and it passes:

```bash
make replay
```

Now change the backend. Stop `make api` and start it with the field renamed:

```bash
make api-changed
```

```bash
make replay
```

The frontend's code did not change, and the journey fails, naming the call:

```text
  ✗ shopper loads the item list (items.spec.ts:3) 5.153s
      Error: expect(locator).toHaveText(expected) failed
      answered differently from the recording: GET http://api.localtest.me:8081/items (Body JSON)

Browser journeys: 0 passed, 1 failed, 0 skipped
```

Stop the API, the mock server and the frontend when you finish. `make verify-local` runs steps 2 to 4 in one go and checks each result.

## 5. Run it in a cluster

This step creates a disposable minikube profile called `browser-journeys`, installs the released Speedscale operator with no image overrides, and deploys the frontend and the API. The operator needs your API key to start. Copy it from the [dashboard](https://app.speedscale.com/tenant):

```bash
export SPEEDSCALE_API_KEY=<key>
```

```bash
make up
```

`make up` leaves your default kubectl context as it was, and every command below names its context. It also rewrites `api.localtest.me` in the cluster's DNS to the `shop-api` Service, so `--no-mocks` has a real API to reach. To choose a minikube driver or size, set `MINIKUBE_START_ARGS`, for example `MINIKUBE_START_ARGS="--driver=docker --cpus=4 --memory=6144"`.

Run the journey with its API calls answered from the recording:

```bash
make cluster
```

This runs the following, and the first run takes a few minutes while the cluster pulls the `generator-browser` image:

```bash
proxymock cluster replay start --kube-context browser-journeys \
  --target http://shop-spa.browser-journeys:80 --in proxymock/recording \
  --browser journeys --test-config config/browser-journeys-mocks.json --wait -o pretty
```

The journey and the recording are staged in the cluster's forwarder, with no cloud round trip. The operator starts a generator pod with Chromium and a responder beside it, and the responder answers the frontend's API calls. `shop-api` is running, but nothing reaches it. A recording made on `localhost:3000` replays against a frontend on another origin, because the responder answers with the requesting origin.

```text
  mocks:     the browser's API calls, by a responder in the generator pod
result: Passed (success rate 100.0%)
goals (0 of 2 missed):
  PASS browserLcpP95: expected <= 5,000, actual 28
  PASS browserJourneyPassPct: expected >= 100, actual 100
```

Run the failing journeys:

```bash
make cluster-failing
```

The replay misses its goals, the command exits nonzero, and each failed journey's screenshot, trace and error context are downloaded to `browser-artifacts/<report id>/`:

```text
result: Missed Goals (success rate 33.3%)
  FAIL browserJourneyPassPct: expected >= 100, actual 33.33
screenshots and traces of failed journeys, saved to browser-artifacts/<report id>:
```

Now turn mocks off, so every call goes to the real `shop-api`:

```bash
make cluster-real
```

It passes. Change the API in the cluster and run it again:

```bash
make change-api
```

```bash
make cluster-real
```

The journey fails. A cloud-free run doesn't compare the calls with the recording, so this result only says that the journey failed. Step 6 runs the same thing with the comparison on.

`make verify-cluster` runs this step's replays in one go and checks each result. It leaves the API restored.

## 6. Read the report

With `--snapshot-source cloud`, the snapshot and report go to Speedscale cloud and the report opens in the dashboard. proxymock has to be signed in to the same account as the operator. Restore the API and run the failing journeys:

```bash
make restore-api
```

```bash
make cloud-failing
```

The command prints a `report at:` link. With a cloud report, `--wait` follows the replay until it finishes and exits 0, so read the verdict in the report. Open the report's **Journeys** tab:

- The top of the tab counts the journeys and shows p95 web vitals.
- Expand **shopper pages through the items** to see its steps. Each step shows how many calls it made, and the click on **Next page** names the call the recording could not answer.
- Expand **shopper sees a checkout button**. No call is flagged. Under its steps are the screenshot Playwright took when it failed and the downloads.
- Select **Open trace** to replay the journey in Playwright's trace viewer inside the dashboard. It shows each action, a snapshot of the page, the console and the network calls. The trace is read in your browser.

Now run the backend change with the cloud comparing the answers:

```bash
make change-api
```

```bash
make cloud-real
```

In this report, the **Journeys** tab names `GET http://api.localtest.me:8081/items` under the click that made it, as answered differently from the recording, with `(Body JSON)` as what differed. The **Errors** tab shows the same call as a failed **Browser Call** assertion. Restore the API with `make restore-api` when you finish.

To start the same replay from the dashboard, open `/replay-launcher?snapshotId=<snapshot id>` with the snapshot id the command printed, then follow [these steps](https://docs.speedscale.com/guides/browser-journeys/run-in-cluster/#from-the-dashboard).

## Clean up

```bash
make down
```

```bash
make clean
```

## If something looks wrong

- **A cloud run with mocks on shows every call as a passthrough.** Don't reuse one test config id for mocks on and `--no-mocks`. A cloud-free run stages its config in the cluster's forwarder, and a later cloud run with the same id reads the staged copy, including whether it observes the real APIs. That is why `config/` has one file per mode.
- **A call shows as failed with no status, and is not named as a miss.** A frontend that never reads a failed response's body leaves the request open until the page closes, and Playwright reports it as aborted. `app/site/index.html` reads the body before checking the status for that reason. If your own frontend does not, the journey still fails, but the miss may not be named.
- **`make up` stops with an image pull error.** Check the runtime has room. A generator-browser image is about 2 GB once unpacked, and the pod also takes a 1 GiB memory-backed `/dev/shm`.
- **`proxymock record --browser` says it cannot find Playwright.** Run it from this directory, after `make install`.
- **The result lists a plain request count and no goals.** The replay ran as a request replay, not a browser one. Check `proxymock version` and the operator's image are both v2.5.1274 or newer.
