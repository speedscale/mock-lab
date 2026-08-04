.PHONY: test build observability-up observability-down catalog app record mock functional-replay load-replay

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results

test:
	go test ./...

build:
	mkdir -p bin
	go build -o bin/catalog ./cmd/catalog
	go build -o bin/app ./cmd/app

observability-up:
	docker compose up -d

observability-down:
	docker compose down

catalog:
	go run ./cmd/catalog

app:
	go run ./cmd/app

record: build
	mkdir -p $(RECORDING_DIR)
	$(PROXYMOCK) record --out $(RECORDING_DIR) -- ./bin/app

mock: build
	$(PROXYMOCK) mock --in $(RECORDING_DIR) --no-passthrough --no-out -- ./bin/app

functional-replay:
	mkdir -p $(RESULTS_DIR)/functional
	$(PROXYMOCK) replay --in $(RECORDING_DIR) --out $(RESULTS_DIR)/functional --test-against http://localhost:8080 --times 3 --fail-if 'requests.failed>0'

load-replay:
	mkdir -p $(RESULTS_DIR)/load
	@start=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	$(PROXYMOCK) replay --in $(RECORDING_DIR) --out $(RESULTS_DIR)/load --test-against http://localhost:8080 --load-test --vus 8 --for 45s; \
	replay_status=$$?; \
	end=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	printf '{\n  "start": "%s",\n  "end": "%s"\n}\n' "$$start" "$$end" > $(RESULTS_DIR)/load/profile-window.json; \
	exit $$replay_status
