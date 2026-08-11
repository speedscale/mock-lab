.PHONY: test build observability-up observability-down inventory app record mock functional-replay load-replay

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results

test:
	go test ./...

build:
	mkdir -p bin
	go build -o bin/inventory ./cmd/inventory
	go build -o bin/app ./cmd/app
	go build -o bin/utc-now ./cmd/utc-now

observability-up:
	docker compose up -d

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
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --mock-timing 35x --no-passthrough --no-out -- ./bin/app

functional-replay: build
	@rm -rf "$(RESULTS_DIR)/functional"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/functional/window.json"; \
	temporary_window="$(RESULTS_DIR)/.functional-window.json.tmp"; \
	summary="$(RESULTS_DIR)/functional/summary.json"; \
	temporary_summary="$(RESULTS_DIR)/.functional-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --out "$(RESULTS_DIR)/functional" --test-against http://localhost:8080 --times 3 --output json --fail-if 'requests.failed>0' > "$$temporary_summary"; then \
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

load-replay: build
	@rm -rf "$(RESULTS_DIR)/load"
	@mkdir -p "$(RESULTS_DIR)"
	@window="$(RESULTS_DIR)/load/window.json"; \
	temporary_window="$(RESULTS_DIR)/.load-window.json.tmp"; \
	summary="$(RESULTS_DIR)/load/summary.json"; \
	temporary_summary="$(RESULTS_DIR)/.load-summary.json.tmp"; \
	start=$$(./bin/utc-now); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --no-out --test-against http://localhost:8080 --load-test --vus 4 --for 30s --output json --fail-if 'requests.failed>0' > "$$temporary_summary"; then \
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
