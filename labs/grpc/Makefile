.PHONY: test build record mock replay check web gen clean

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results

test:
	go vet ./...

build:
	mkdir -p bin
	go build -buildvcs=false -o bin/ ./cmd/...

# Record the client's calls to the orders service, and the service's Pub/Sub
# and OTLP calls, against local fakes. Replaces the checked-in recording.
record: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(RECORDING_DIR)" ./scripts/record.sh

# Answer the orders service's Pub/Sub and OTLP calls from the recording, on the
# same ports the service records through. Runs in the foreground.
mock:
	$(PROXYMOCK) mock --in "$(RECORDING_DIR)" --out "$(RESULTS_DIR)/mocked" \
		--map 18085=localhost:8085 --map 14317=localhost:4317

# Replay the recorded calls against the orders service with its dependencies
# mocked, offline, and compare every response with the recording.
replay: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(RECORDING_DIR)" RESULTS_DIR="$(RESULTS_DIR)" ./scripts/replay.sh

# Print how each recorded body resolves to a message type, with its fields named.
check:
	$(PROXYMOCK) protos check "$(RECORDING_DIR)" --show named

web:
	$(PROXYMOCK) web

# Regenerate gen/ after changing proxymock/protos: GOOGLEAPIS=/path/to/googleapis make gen
gen:
	./scripts/gen.sh

clean:
	rm -rf bin .run "$(RESULTS_DIR)"
