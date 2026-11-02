.PHONY: install site api api-changed record mock mock-real replay replay-failing verify-local \
	up deploy change-api restore-api cluster cluster-failing cluster-real \
	cloud cloud-failing cloud-real verify-cluster down clean

PROXYMOCK ?= proxymock
KUBE_CONTEXT ?= browser-journeys
RECORDING ?= proxymock/recording
RECORD_TO ?= proxymock/my-recording
FRONTEND ?= http://localhost:3000
CLUSTER_FRONTEND ?= http://shop-spa.browser-journeys:80
MOCKS_CONFIG ?= config/browser-journeys-mocks.json
REAL_CONFIG ?= config/browser-journeys-real.json

CLUSTER_REPLAY = $(PROXYMOCK) cluster replay start --kube-context $(KUBE_CONTEXT) \
	--target $(CLUSTER_FRONTEND) --in $(RECORDING) --wait -o pretty

# Playwright and Chromium, in this directory, where proxymock finds them.
install:
	npm ci
	npx playwright install chromium

# The frontend on http://localhost:3000. Leave it running in its own terminal.
site:
	node app/serve-site.js

# The real API on http://api.localtest.me:8081.
api:
	node app/api/server.js

# The same API after a backend change: "name" is now "title".
api-changed:
	ITEM_FIELD=title node app/api/server.js

# Opens Chromium with Playwright's codegen. Click through a journey, then close the window.
record:
	PROXYMOCK="$(PROXYMOCK)" RECORD_TO="$(RECORD_TO)" FRONTEND="$(FRONTEND)" ./scripts/record.sh

mock:
	$(PROXYMOCK) mock --in $(RECORDING) --no-passthrough

mock-real:
	$(PROXYMOCK) mock --in $(RECORDING) --observe-real-apis

replay:
	$(PROXYMOCK) replay --in $(RECORDING) --browser journeys \
		--test-against $(FRONTEND) --browser-proxy http://localhost:4140 \
		--out proxymock/results/journeys

replay-failing:
	$(PROXYMOCK) replay --in $(RECORDING) --browser journeys-failing \
		--test-against $(FRONTEND) --browser-proxy http://localhost:4140 --browser-workers 2 \
		--out proxymock/results/journeys-failing

# Runs every local step and checks each result.
verify-local:
	PROXYMOCK="$(PROXYMOCK)" ./scripts/verify-local.sh

# A disposable cluster with the released operator and the shop. Needs SPEEDSCALE_API_KEY.
up:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./scripts/up.sh

deploy:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./scripts/deploy.sh

change-api:
	kubectl --context $(KUBE_CONTEXT) -n browser-journeys set env deployment/shop-api ITEM_FIELD=title
	kubectl --context $(KUBE_CONTEXT) -n browser-journeys rollout status deployment/shop-api --timeout=2m

restore-api:
	kubectl --context $(KUBE_CONTEXT) -n browser-journeys set env deployment/shop-api ITEM_FIELD-
	kubectl --context $(KUBE_CONTEXT) -n browser-journeys rollout status deployment/shop-api --timeout=2m

# Mocks on, nothing leaves the cluster, the report stays in the forwarder.
cluster:
	$(CLUSTER_REPLAY) --browser journeys --test-config $(MOCKS_CONFIG)

cluster-failing:
	$(CLUSTER_REPLAY) --browser journeys-failing --test-config $(MOCKS_CONFIG)

# Mocks off: every call goes to the real shop-api.
cluster-real:
	$(CLUSTER_REPLAY) --browser journeys --test-config $(REAL_CONFIG) --no-mocks

# The same runs with the snapshot and report in Speedscale cloud, for the dashboard.
cloud:
	$(CLUSTER_REPLAY) --browser journeys --test-config $(MOCKS_CONFIG) \
		--snapshot-source cloud --name browser-journeys-lab

cloud-failing:
	$(CLUSTER_REPLAY) --browser journeys-failing --test-config $(MOCKS_CONFIG) \
		--snapshot-source cloud --name browser-journeys-lab-failing

cloud-real:
	$(CLUSTER_REPLAY) --browser journeys --test-config $(REAL_CONFIG) --no-mocks \
		--snapshot-source cloud --name browser-journeys-lab-real

# Runs every cloud-free cluster step and checks each result.
verify-cluster:
	PROXYMOCK="$(PROXYMOCK)" KUBE_CONTEXT="$(KUBE_CONTEXT)" ./scripts/verify-cluster.sh

down:
	minikube delete -p "$${MINIKUBE_PROFILE:-browser-journeys}"

clean:
	rm -rf proxymock/my-recording proxymock/results browser-artifacts test-results
