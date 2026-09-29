.PHONY: build verify

build:
	mkdir -p bin
	go build -o bin/service ./cmd/service
	go build -o bin/backend ./cmd/backend

verify: build
	bash ./scripts/verify.sh
