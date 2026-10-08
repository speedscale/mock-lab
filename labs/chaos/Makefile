.PHONY: capture coverage mock mock-chaos mock-chaos-record mock-flaky mock-slow web verify-mock verify baseline chaos-evidence slow-evidence clean

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
CAPTURE_DIR ?= proxymock/recorded-local
APP_URL ?= http://127.0.0.1:8080
MOCK_HEALTH_PORT ?= 4141
MOCK_HEALTH_URL ?= http://127.0.0.1:$(MOCK_HEALTH_PORT)
WEB_PORT ?= 7788
SKUS ?= SSC-4110 SSC-4111 SSC-5200 SSC-5201 SSC-6100 SSC-7300

# The scope is a filter query - the same one the Requests grid and
# --query-string use. Every group must be parenthesized.
CHAOS_SCOPE ?= (url CONTAINS "/v1/inventory")
CHAOS_RULE ?= $(CHAOS_SCOPE): status=503,percent=100
CHAOS_RULE_FLAKY ?= $(CHAOS_SCOPE): status=503,percent=50,seed=lab
CHAOS_RULE_SLOW ?= $(CHAOS_SCOPE): latency=2s

# Record one ordinary session with inventory healthy. Nothing rare happens.
capture:
	RECORDING_DIR="$(CAPTURE_DIR)" PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

coverage:
	npm run coverage

# Serve the recorded inventory and run the storefront against it, untouched.
mock:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --mock-timing none --out proxymock/results/healthy \
		--health-port $(MOCK_HEALTH_PORT) -- node app.js

# The same run with inventory failing every call, and nothing else touched.
mock-chaos:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --mock-timing none --out proxymock/results/chaos \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE)' -- node app.js

# Half the calls fail, deterministically. This is the one to run after a fix:
# it exercises the healthy path, the degraded path, and the transition.
mock-flaky:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --mock-timing none --out proxymock/results/flaky \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE_FLAKY)' -- node app.js

# Delay only inventory responses to test the storefront's latency budget.
mock-slow:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --mock-timing none --out proxymock/results/slow \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE_SLOW)' -- node app.js

# Retain a mixed healthy/faulted run for the web Requests grid.
mock-chaos-record:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE_FLAKY)' -- node app.js

# Browse the run: the Chaos column, the "chaos applied" filter, and the
# per-pair banner naming the rule that fired.
web:
	$(PROXYMOCK) web --port $(WEB_PORT)

verify-mock:
	@curl --fail --silent --show-error "$(MOCK_HEALTH_URL)" >/dev/null || { \
		echo "proxymock is not ready at $(MOCK_HEALTH_URL). Start 'make mock' or 'make mock-chaos' in another terminal." >&2; \
		exit 1; \
	}
	@curl --fail --silent --show-error "$(APP_URL)/healthz" >/dev/null || { \
		echo "storefront is not ready at $(APP_URL). Wait for proxymock to start it, then retry." >&2; \
		exit 1; \
	}

# Ask about every SKU and print what the storefront claims.
baseline: verify-mock
	@for sku in $(SKUS); do curl --silent --show-error "$(APP_URL)/api/stock/$$sku"; done

# What inventory is really answering, straight off the mock server, so the
# storefront's claim can be checked against it.
chaos-evidence: verify-mock
	@curl --silent --show-error --noproxy "" --proxy http://127.0.0.1:4140 --dump-header - \
		"http://localhost:8090/v1/inventory/SSC-4110" \
		| grep -Ei '^HTTP|^X-Speedscale-Chaos|^\{'

# Measure one app response while its inventory dependency is slow.
slow-evidence: verify-mock
	@curl --silent --show-error --output /dev/null --write-out 'http=%{http_code} elapsed=%{time_total}s\n' \
		"$(APP_URL)/api/stock/SSC-4110"

verify: verify-mock baseline

clean:
	rm -rf scratch
