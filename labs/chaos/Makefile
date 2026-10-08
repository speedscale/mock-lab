.PHONY: capture coverage mock web verify-mock verify baseline clean

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
CAPTURE_DIR ?= proxymock/recorded-local
APP_URL ?= http://127.0.0.1:8080
MOCK_HEALTH_PORT ?= 4141
MOCK_HEALTH_URL ?= http://127.0.0.1:$(MOCK_HEALTH_PORT)
WEB_PORT ?= 7788
SKUS ?= SSC-4110 SSC-4111 SSC-5200 SSC-5201 SSC-6100 SSC-7300

# Record one ordinary session with inventory healthy. Nothing rare happens.
capture:
	RECORDING_DIR="$(CAPTURE_DIR)" PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

coverage:
	npm run coverage

# Serve the recorded inventory and run the storefront against it, untouched.
mock:
	NODE_USE_ENV_PROXY=1 NO_PROXY= no_proxy= $(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --mock-timing none --out proxymock/results/healthy \
		--health-port $(MOCK_HEALTH_PORT) -- node app.js

# Browse retained native traffic.
web:
	$(PROXYMOCK) web --port $(WEB_PORT)

verify-mock:
	@curl --fail --silent --show-error "$(MOCK_HEALTH_URL)" >/dev/null || { \
		echo "proxymock is not ready at $(MOCK_HEALTH_URL). Start 'make mock' in another terminal." >&2; \
		exit 1; \
	}
	@curl --fail --silent --show-error "$(APP_URL)/healthz" >/dev/null || { \
		echo "storefront is not ready at $(APP_URL). Wait for proxymock to start it, then retry." >&2; \
		exit 1; \
	}

# Ask about every SKU and print what the storefront claims.
baseline: verify-mock
	@for sku in $(SKUS); do curl --silent --show-error "$(APP_URL)/api/stock/$$sku"; done

verify: verify-mock baseline

clean:
	rm -rf scratch
