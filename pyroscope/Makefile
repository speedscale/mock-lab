.PHONY: test build observability-up observability-down catalog app record mock functional-replay load-replay \
	opencost-up opencost-down opencost-build opencost-forward opencost-stop \
	opencost-deploy-baseline opencost-deploy-candidate \
	opencost-functional-baseline opencost-functional-candidate \
	opencost-load-baseline opencost-load-candidate \
	opencost-query-baseline opencost-query-candidate opencost-compare

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
	mkdir -p "$(RESULTS_DIR)/load"
	@rm -f "$(RESULTS_DIR)/load/profile-window.json" "$(RESULTS_DIR)/load/profile-window.json.tmp"
	@test -d "$(RECORDING_DIR)" || { echo 'recording directory "$(RECORDING_DIR)" does not exist' >&2; exit 1; }
	@window="$(RESULTS_DIR)/load/profile-window.json"; \
	temporary_window="$$window.tmp"; \
	start=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	if $(PROXYMOCK) replay --in "$(RECORDING_DIR)" --out "$(RESULTS_DIR)/load" --test-against http://localhost:8080 --load-test --vus 8 --for 45s; then \
		end=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
		printf '{\n  "start": "%s",\n  "end": "%s"\n}\n' "$$start" "$$end" > "$$temporary_window"; \
		mv "$$temporary_window" "$$window"; \
	else \
		replay_status=$$?; \
		echo 'load replay failed; profile-window.json was not written' >&2; \
		exit $$replay_status; \
	fi

opencost-up:
	./scripts/opencost-up.sh

opencost-stop:
	minikube pause -p "$${MINIKUBE_PROFILE:-opencost-lab}"

opencost-down:
	minikube delete -p "$${MINIKUBE_PROFILE:-opencost-lab}"

opencost-build:
	docker build -t mock-lab-catalog:local -f Dockerfile.opencost .
	minikube -p "$${MINIKUBE_PROFILE:-opencost-lab}" image load mock-lab-catalog:local

opencost-forward:
	./scripts/opencost-forward.sh

opencost-deploy-baseline:
	./scripts/opencost-deploy.sh baseline

opencost-deploy-candidate:
	./scripts/opencost-deploy.sh candidate

opencost-functional-baseline:
	./scripts/opencost-replay.sh functional baseline

opencost-functional-candidate:
	./scripts/opencost-replay.sh functional candidate

opencost-load-baseline:
	./scripts/opencost-replay.sh load baseline

opencost-load-candidate:
	./scripts/opencost-replay.sh load candidate

opencost-query-baseline:
	./scripts/opencost-query.sh baseline

opencost-query-candidate:
	./scripts/opencost-query.sh candidate

opencost-compare:
	./scripts/opencost-compare.sh
