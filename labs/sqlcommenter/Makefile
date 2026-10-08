.PHONY: test build up down capture report web

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

report:
	$(PROXYMOCK) sql-report --in "$(RECORDING_DIR)" -o pretty

web:
	$(PROXYMOCK) web --in "$(RECORDING_DIR)"
