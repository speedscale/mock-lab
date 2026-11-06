.PHONY: install site site-buggy api api-slow team-tests record mock mock-real \
	regression regression-writes perf record-api load verify-local clean

PROXYMOCK ?= proxymock
FRONTEND ?= http://localhost:3000
RECORDING ?= proxymock/recording
API_RECORDING ?= proxymock/api-recording
BLOCK ?= --browser-block '**/favicon.ico'

REPLAY = $(PROXYMOCK) replay --in $(RECORDING) --test-against $(FRONTEND) \
	--browser-proxy http://localhost:4140 --browser-ignore-https-errors $(BLOCK)

# Playwright and Chromium, in this directory, where proxymock finds them.
install:
	npm ci
	npx playwright install chromium

# The frontend on http://localhost:3000. Leave it running in its own terminal.
site:
	node app/serve-site.js

# The same frontend with a search bug: it sends ?query= instead of ?q=.
site-buggy:
	SITE_BUG=search node app/serve-site.js

# The API on http://api.localtest.me:8082.
api:
	node app/api/server.js

# The same API after a change that adds 800ms to every response.
api-slow:
	LATENCY_MS=800 node app/api/server.js

# The team's suite as it was before the skill ported it.
team-tests:
	npx playwright test -c tests --project chromium

# Runs the journeys once through proxymock record's outbound proxy, headless.
record:
	PROXYMOCK="$(PROXYMOCK)" RECORD_TO="$(RECORDING)" FRONTEND="$(FRONTEND)" ./scripts/record.sh

# API calls answered from the recording; a call it cannot answer gets a 404.
mock:
	$(PROXYMOCK) mock --in $(RECORDING) --no-passthrough

# API calls sent to the real API and compared with the recording.
mock-real:
	$(PROXYMOCK) mock --in $(RECORDING) --observe-real-apis

# The regression gate: every read-only journey passes.
regression:
	$(REPLAY) --browser journeys/read-only --test-config playwright-gates-regression \
		--out proxymock/results/regression

# The write journey. Your own machine only.
regression-writes:
	$(REPLAY) --browser journeys/writes --test-config playwright-gates-regression \
		--out proxymock/results/writes

# The performance gate, Tier A: web-vitals budgets on the perf journeys.
perf:
	$(REPLAY) --browser journeys/perf --browser-workers 3 --test-config playwright-gates-perf \
		--out proxymock/results/perf

# Tier B, step 1: record the API's inbound traffic while the journeys drive the frontend.
record-api:
	PROXYMOCK="$(PROXYMOCK)" RECORD_TO="$(API_RECORDING)" ./scripts/record-api.sh

# Tier B, step 2: replay that traffic at the API as a load test, with SLO gates.
load:
	$(PROXYMOCK) replay --in $(API_RECORDING) --test-against http://localhost:8082 \
		--vus 8 --for 20s --load-test --no-out \
		--fail-if 'latency.p95>50' --fail-if 'requests.failed!=0'

# Runs every step above and checks each result.
verify-local:
	PROXYMOCK="$(PROXYMOCK)" ./scripts/verify-local.sh

clean:
	rm -rf proxymock/results proxymock/my-recording proxymock/my-api-recording test-results
