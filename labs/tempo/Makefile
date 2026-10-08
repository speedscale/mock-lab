.PHONY: test build observability-up observability-down inventory app record mock verify-tempo verify-mock verify-functional functional-replay load-replay

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results
TARGET_URL ?= http://localhost:8080
MOCK_HEALTH_PORT ?= 4141
MOCK_HEALTH_URL ?= http://localhost:$(MOCK_HEALTH_PORT)
TARGET_HEALTH_URL ?= $(TARGET_URL)/healthz
TEMPO_READY_URL ?= http://localhost:3200/ready

test:
	go test ./...

build:
	mkdir -p bin
	go build -o bin/inventory ./cmd/inventory
	go build -o bin/app ./cmd/app
	go build -o bin/utc-now ./cmd/utc-now

observability-up:
	docker compose up -d
	@$(MAKE) verify-tempo

observability-down:
	docker compose down

inventory:
	go run ./cmd/inventory

app:
	go run ./cmd/app

record: build
	mkdir -p "$(RECORDING_DIR)"
	$(PROXYMOCK) record --out "$(RECORDING_DIR)" -- ./bin/app

mock: build
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --mock-timing 35x --no-passthrough --no-out --health-port $(MOCK_HEALTH_PORT) -- ./bin/app

verify-tempo:
	@attempt=0; \
	until curl --fail --silent --show-error "$(TEMPO_READY_URL)" >/dev/null; do \
		attempt=$$((attempt + 1)); \
		if [ $$attempt -ge 15 ]; then \
			echo "Tempo is not ready at $(TEMPO_READY_URL). Inspect 'docker compose ps' and 'docker compose logs tempo'." >&2; \
			exit 1; \
		fi; \
		sleep 2; \
	done

verify-mock:
	@curl --fail --silent --show-error "$(MOCK_HEALTH_URL)" >/dev/null || { \
		echo "proxymock mock is not ready at $(MOCK_HEALTH_URL). Stop 'make record', then start 'make mock' in a separate terminal." >&2; \
		exit 1; \
	}
	@curl --fail --silent --show-error "$(TARGET_HEALTH_URL)" >/dev/null || { \
		echo "catalog app is not ready at $(TARGET_HEALTH_URL). Wait for 'make mock' to start the app, then retry." >&2; \
		exit 1; \
	}

verify-functional:
	@summary="$(RESULTS_DIR)/functional/summary.json"; \
	test -f "$$summary" || { echo "missing $$summary; run the functional replay successfully before load" >&2; exit 1; }; \
	jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0 and .metrics["requests.result-match-pct"] == 100)' "$$summary" >/dev/null || { \
		echo "functional behavior did not match 100%; refusing to collect load evidence" >&2; \
		exit 1; \
	}

functional-replay: build verify-tempo verify-mock
	@rm -rf "$(RESULTS_DIR)/functional"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/functional/window.json"; \
	temporary_window="$(RESULTS_DIR)/.functional-window.json.tmp"; \
	summary="$(RESULTS_DIR)/functional/summary.json"; \
	temporary_summary="$(RESULTS_DIR)/.functional-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --out "$(RESULTS_DIR)/functional" --test-against "$(TARGET_URL)" --times 3 --output json --fail-if 'requests.failed!=0' --fail-if 'requests.result-match-pct!=100' > "$$temporary_summary"; then \
		end=$$(./bin/utc-now); \
		printf '{\n  "start": "%s",\n  "end": "%s"\n}\n' "$$start" "$$end" > "$$temporary_window"; \
		mkdir -p "$(RESULTS_DIR)/functional"; \
		mv "$$temporary_summary" "$$summary"; \
		mv "$$temporary_window" "$$window"; \
	else \
		replay_status=$$?; \
		rm -f "$$temporary_window" "$$temporary_summary"; \
		exit $$replay_status; \
	fi

load-replay: build verify-mock verify-functional
	@rm -rf "$(RESULTS_DIR)/load"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/load/window.json"; \
	temporary_window="$(RESULTS_DIR)/.load-window.json.tmp"; \
	summary="$(RESULTS_DIR)/load/summary.json"; \
	temporary_summary="$(RESULTS_DIR)/.load-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --no-out --test-against "$(TARGET_URL)" --load-test --vus 4 --for 30s --output json --fail-if 'requests.failed!=0' > "$$temporary_summary"; then \
		end=$$(./bin/utc-now); \
		printf '{\n  "start": "%s",\n  "end": "%s"\n}\n' "$$start" "$$end" > "$$temporary_window"; \
		mkdir -p "$(RESULTS_DIR)/load"; \
		mv "$$temporary_summary" "$$summary"; \
		mv "$$temporary_window" "$$window"; \
	else \
		replay_status=$$?; \
		rm -f "$$temporary_window" "$$temporary_summary"; \
		exit $$replay_status; \
	fi
