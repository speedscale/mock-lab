.PHONY: build capture mock mock-flaky verify-mock verify baseline chaos-evidence clean

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
APP_URL ?= http://127.0.0.1:8080
MOCK_HEALTH_PORT ?= 4141
MOCK_HEALTH_URL ?= http://127.0.0.1:$(MOCK_HEALTH_PORT)
SKUS ?= SSC-4110 SSC-4111 SSC-5200 SSC-5201 SSC-6100 SSC-7300

# The scope is a filter query - the same one the Requests grid and
# --query-string use. Every group must be parenthesized.
CHAOS_SCOPE ?= (url CONTAINS "/v1/inventory")
CHAOS_RULE ?= $(CHAOS_SCOPE): status=503,percent=100
CHAOS_RULE_FLAKY ?= $(CHAOS_SCOPE): status=503,percent=50,seed=lab

build:
	mkdir -p bin
	go build -o bin/app ./cmd/app
	go build -o bin/inventory ./cmd/inventory

# Record one ordinary session with inventory healthy. Nothing rare happens.
capture: build
	RECORDING_DIR="$(RECORDING_DIR)" PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

# Serve the recorded inventory and run the storefront against it, untouched.
mock: build
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --no-out \
		--health-port $(MOCK_HEALTH_PORT) -- ./bin/app

# The same run with inventory failing every call, and nothing else touched.
mock-chaos: build
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --no-out \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE)' -- ./bin/app

# Half the calls fail, deterministically. This is the one to run after a fix:
# it exercises the healthy path, the degraded path, and the transition.
mock-flaky: build
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --no-out \
		--health-port $(MOCK_HEALTH_PORT) --chaos '$(CHAOS_RULE_FLAKY)' -- ./bin/app

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
	@curl --silent --show-error --proxy http://127.0.0.1:4140 --dump-header - \
		"http://localhost:8090/v1/inventory/SSC-4110" \
		| grep -E '^HTTP|^X-Speedscale-Chaos|^\{'

verify: verify-mock baseline

clean:
	rm -rf bin scratch
