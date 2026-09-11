.PHONY: test build up down pricing capture mock verify-loki verify-mock verify-functional functional-replay load-replay verify logs-reset

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results
TARGET_URL ?= http://localhost:8080
MOCK_HEALTH_PORT ?= 4141
MOCK_HEALTH_URL ?= http://localhost:$(MOCK_HEALTH_PORT)
TARGET_HEALTH_URL ?= $(TARGET_URL)/healthz
LOKI_READY_URL ?= http://localhost:3100/ready
LOG_FILE ?= scratch/logs/checkout.log
LOAD_VUS ?= 4
LOAD_TIMES ?= 25
# Alloy tails and pushes on a short interval; the settle pause keeps the last
# lines of a replay inside the published query window.
LOG_SETTLE_SECONDS ?= 6

test:
	go test ./...

build:
	mkdir -p bin scratch/logs
	go build -o bin/app ./cmd/app
	go build -o bin/pricing ./cmd/pricing
	go build -o bin/utc-now ./cmd/utc-now
	go build -o bin/mkwindow ./cmd/mkwindow

up: build
	docker compose up -d
	@$(MAKE) verify-loki

down:
	docker compose down -v

pricing: build
	./bin/pricing

capture: build
	RECORDING_DIR="$(RECORDING_DIR)" PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

mock: build
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --no-passthrough --no-out --health-port $(MOCK_HEALTH_PORT) -- ./bin/app

verify-loki:
	@attempt=0; \
	until curl --fail --silent --show-error "$(LOKI_READY_URL)" 2>/dev/null | grep -q ready; do \
		attempt=$$((attempt + 1)); \
		if [ $$attempt -ge 30 ]; then \
			echo "Loki is not ready at $(LOKI_READY_URL). Inspect 'docker compose ps' and 'docker compose logs loki'." >&2; \
			exit 1; \
		fi; \
		sleep 2; \
	done

verify-mock:
	@curl --fail --silent --show-error "$(MOCK_HEALTH_URL)" >/dev/null || { \
		echo "proxymock mock is not ready at $(MOCK_HEALTH_URL). Stop 'make capture', then start 'make mock' in a separate terminal." >&2; \
		exit 1; \
	}
	@curl --fail --silent --show-error "$(TARGET_HEALTH_URL)" >/dev/null || { \
		echo "checkout app is not ready at $(TARGET_HEALTH_URL). Wait for 'make mock' to start the app, then retry." >&2; \
		exit 1; \
	}

verify-functional:
	@summary="$(RESULTS_DIR)/functional/summary.json"; \
	test -f "$$summary" || { echo "missing $$summary; run the functional replay successfully before load" >&2; exit 1; }; \
	jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0 and .metrics["requests.result-match-pct"] == 100)' "$$summary" >/dev/null || { \
		echo "functional behavior did not match 100%; refusing to collect load evidence" >&2; \
		exit 1; \
	}

functional-replay: build verify-loki verify-mock
	@rm -rf "$(RESULTS_DIR)/functional"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/functional/window.json"; \
	temporary_summary="$(RESULTS_DIR)/.functional-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --out "$(RESULTS_DIR)/functional" --test-against "$(TARGET_URL)" --times 1 --output json --fail-if 'requests.failed!=0' --fail-if 'requests.result-match-pct!=100' > "$$temporary_summary"; then \
		sleep $(LOG_SETTLE_SECONDS); \
		end=$$(./bin/utc-now); \
		mkdir -p "$(RESULTS_DIR)/functional"; \
		mv "$$temporary_summary" "$(RESULTS_DIR)/functional/summary.json"; \
		./bin/mkwindow "$$start" "$$end" > "$$window"; \
	else \
		replay_status=$$?; \
		rm -f "$$temporary_summary"; \
		exit $$replay_status; \
	fi

load-replay: build verify-mock verify-functional
	@rm -rf "$(RESULTS_DIR)/load"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/load/window.json"; \
	temporary_summary="$(RESULTS_DIR)/.load-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --no-out --test-against "$(TARGET_URL)" --load-test --vus $(LOAD_VUS) --times $(LOAD_TIMES) --output json --fail-if 'requests.failed!=0' > "$$temporary_summary"; then \
		sleep $(LOG_SETTLE_SECONDS); \
		end=$$(./bin/utc-now); \
		mkdir -p "$(RESULTS_DIR)/load"; \
		mv "$$temporary_summary" "$(RESULTS_DIR)/load/summary.json"; \
		./bin/mkwindow "$$start" "$$end" > "$$window"; \
	else \
		replay_status=$$?; \
		rm -f "$$temporary_summary"; \
		exit $$replay_status; \
	fi

verify:
	@$(MAKE) verify-functional RESULTS_DIR="$(RESULTS_DIR)"
	@summary="$(RESULTS_DIR)/load/summary.json"; \
	test -f "$$summary" || { echo "missing $$summary; run the load replay successfully first" >&2; exit 1; }; \
	jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0)' "$$summary" >/dev/null || { \
		echo "load replay recorded failed requests" >&2; \
		exit 1; \
	}
	@test -f "$(RESULTS_DIR)/functional/window.json" || { echo "missing functional window.json" >&2; exit 1; }
	@test -f "$(RESULTS_DIR)/load/window.json" || { echo "missing load window.json" >&2; exit 1; }
	@echo "verified: functional gate, load gate, and both windows exist under $(RESULTS_DIR)"
