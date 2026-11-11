.PHONY: test build server slow-server record replay replay-goals load clean

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording
RESULTS_DIR ?= proxymock/results
TARGET_URL ?= http://localhost:8000
FORMAT ?= openai
REQUESTS ?= 8
USAGE ?= true
TTFT_P95_MS ?= 800
ITL_P95_MS ?= 40
LOAD_VUS ?= 4
LOAD_FOR ?= 20s

test:
	go vet ./...

build:
	mkdir -p bin
	go build -buildvcs=false -o bin/model-server ./cmd/model-server
	go build -buildvcs=false -o bin/chat-client ./cmd/chat-client

# The model server reads FIRST_TOKEN_MS, TOKEN_GAP_MS, TOKENS and PORT from the
# environment: make server FIRST_TOKEN_MS=300 TOKEN_GAP_MS=20
server: build
	FIRST_TOKEN_MS=$(or $(FIRST_TOKEN_MS),300) TOKEN_GAP_MS=$(or $(TOKEN_GAP_MS),20) ./bin/model-server

slow-server: build
	FIRST_TOKEN_MS=900 TOKEN_GAP_MS=50 ./bin/model-server

record: build
	PROXYMOCK="$(PROXYMOCK)" RECORDING_DIR="$(RECORDING_DIR)" FORMAT="$(FORMAT)" \
		REQUESTS="$(REQUESTS)" USAGE="$(USAGE)" ./scripts/record.sh

replay:
	$(PROXYMOCK) replay --in "$(RECORDING_DIR)" --test-against "$(TARGET_URL)" \
		--out "$(RESULTS_DIR)/replay" \
		--fail-if 'llm.ttft-p95 > $(TTFT_P95_MS)' \
		--fail-if 'llm.itl-p95 > $(ITL_P95_MS)'

replay-goals:
	$(PROXYMOCK) replay --in "$(RECORDING_DIR)" --test-against "$(TARGET_URL)" \
		--out "$(RESULTS_DIR)/goals" --test-config llm-gates

load:
	$(PROXYMOCK) replay --in "$(RECORDING_DIR)" --test-against "$(TARGET_URL)" \
		--load-test --vus $(LOAD_VUS) --for $(LOAD_FOR) \
		--fail-if 'llm.ttft-p95 > $(TTFT_P95_MS)'

clean:
	rm -rf bin "$(RESULTS_DIR)" proxymock.log
