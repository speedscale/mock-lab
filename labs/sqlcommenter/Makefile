.PHONY: test build up down capture capture-no-otel report web

PROXYMOCK ?= proxymock
RECORDING_DIR ?= proxymock/recording

test:
	go vet ./...
	go test ./...

build:
	mkdir -p bin
	go build -o bin/app .

up:
	docker compose up -d --wait postgres

down:
	docker compose down -v

capture: build
	RECORDING_DIR="$(RECORDING_DIR)" PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

# capture-no-otel records the same load from a service with no tracing at all: the app comments no SQL and no request
# carries a traceparent, so every statement links to its request by timing.
capture-no-otel: build
	SQL_COMMENTS=off TRACEPARENT=off RECORDING_DIR=proxymock/recording-no-otel CAPTURE_LOG=proxymock/capture-no-otel.log \
		PROXYMOCK="$(PROXYMOCK)" ./scripts/capture.sh

report:
	$(PROXYMOCK) sql-report --in "$(RECORDING_DIR)" -o pretty

web:
	$(PROXYMOCK) web --in "$(RECORDING_DIR)"
