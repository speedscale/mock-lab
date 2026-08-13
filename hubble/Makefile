.PHONY: test build hubble-cli up forward down capture break fix probe flows functional-replay load-replay verify

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results/candidate
FAILURE_DIR ?= proxymock/failure

test:
	cd ../go && go test ./...
	cd ../lab/server && go test ./...

build:
	mkdir -p bin
	cd ../tempo && go build -o ../hubble/bin/utc-now ./cmd/utc-now

hubble-cli:
	./scripts/hubble-cli.sh

up: build hubble-cli
	./scripts/up.sh

forward:
	./scripts/forward.sh

capture: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" ./scripts/capture.sh

break:
	./scripts/break.sh

fix:
	./scripts/fix.sh

probe: build
	OUT_DIR="$(abspath $(FAILURE_DIR))" ./scripts/probe.sh

flows:
	WINDOW_FILE="$(abspath $(WINDOW))" ./scripts/flows.sh

functional-replay: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" RESULTS_DIR="$(abspath $(RESULTS_DIR))" ./scripts/replay.sh functional

load-replay: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(abspath $(RECORDING_DIR))" RESULTS_DIR="$(abspath $(RESULTS_DIR))" ./scripts/replay.sh load

verify:
	jq -e 'any(.endpoints[]; .url == "-ALL-" and .method == "-ALL-" and .metrics["requests.failed"] == 0 and .metrics["requests.result-match-pct"] == 100)' "$(RESULTS_DIR)/functional/summary.json" >/dev/null
	test -s "$(RESULTS_DIR)/functional/window.json"
	test -s "$(RESULTS_DIR)/load/window.json"

down:
	minikube delete -p "$${MINIKUBE_PROFILE:-hubble-lab}"
