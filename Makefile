.PHONY: help build test export serve-static run-local demo clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Compile the client and reference server
	go build ./...

test: ## Run the inbound HTTP tests against a running app on :8080
	./tests/run_http_tests.sh

export: ## Render the static JSON tree to ./static (the S3 artifact)
	go run ./server -export ./static

serve-static: export ## Emulate the CloudFront/S3 origin on :8090
	cd static && python3 -m http.server 8090

demo: ## One command: app + static origin on auto-picked free ports, smoke-tested
	./run-local.sh

run-local: ## Run just the app against a downstream (DOWNSTREAM_URL, default trafficreplay)
	go run .

clean:
	rm -rf static proxymock-demo
