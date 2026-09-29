.PHONY: build verify

build:
	mkdir -p bin
	go build -o bin/config-service ./cmd/service
	go build -o bin/config-backend ./cmd/backend

verify: build
	bash scripts/verify.sh
