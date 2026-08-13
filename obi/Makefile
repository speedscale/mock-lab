.PHONY: test build up forward down capture functional-replay load-replay verify

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results/baseline

test:
	cd ../go && go test ./...
	cd ../lab/server && go test ./...

build:
	mkdir -p bin
	cd ../tempo && go build -o ../obi/bin/utc-now ./cmd/utc-now

up: build
	./scripts/up.sh

forward:
	./scripts/forward.sh

capture: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" ./scripts/capture.sh

functional-replay: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" RESULTS_DIR="$(abspath $(RESULTS_DIR))" ./scripts/replay.sh functional

load-replay: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" RESULTS_DIR="$(abspath $(RESULTS_DIR))" ./scripts/replay.sh load

verify:
	jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0 and .metrics["requests.result-match-pct"] == 100)' "$(RESULTS_DIR)/functional/summary.json" >/dev/null
	test -s "$(RESULTS_DIR)/functional/window.json"
	test -s "$(RESULTS_DIR)/load/window.json"

down:
	minikube delete -p "$${MINIKUBE_PROFILE:-obi-lab}"
