.PHONY: build build-go build-java build-node build-python up down reset record mock replay-db replay-twice load web \
	record-all mock-all replay-db-all outage-java test

PROXYMOCK ?= proxymock
APP ?= go
APPS := go java node python
export PROXYMOCK

build: build-go build-java build-node build-python

build-go:
	cd apps/go && go build -buildvcs=false -o bin/shop .

build-java:
	cd apps/java && mvn -q -B package

build-node:
	cd apps/node && npm ci --no-audit --no-fund

build-python:
	cd apps/python && python3 -m venv .venv && .venv/bin/pip install -q -r requirements.txt

# Oracle Database 23ai Free on 127.0.0.1:15210, with db/schema.sql loaded into the shop user's schema
up:
	docker compose up -d --wait oracle
	./scripts/reset.sh --wait

down:
	docker compose down -v

# reload db/schema.sql, so the database holds the rows every recording started from
reset:
	./scripts/reset.sh

record:
	./scripts/record.sh $(APP)

mock:
	./scripts/mock.sh $(APP)

outage-java:
	bash ./scripts/outage-java.sh

replay-db:
	./scripts/replay-db.sh $(APP)

# the same replay run twice without reloading the database in between: the second pass sells stock the first one
# already sold
replay-twice:
	./scripts/replay-db.sh $(APP) --times 2

load:
	./scripts/replay-db.sh $(APP) --vus 4 --for 30s --load-test

web:
	$(PROXYMOCK) web --in proxymock

record-all:
	@for app in $(APPS); do ./scripts/record.sh $$app || exit 1; done

mock-all:
	@for app in $(APPS); do ./scripts/mock.sh $$app || exit 1; done

replay-db-all:
	@for app in $(APPS); do ./scripts/replay-db.sh $$app || exit 1; done

# needs no database: every app runs against the committed recordings
test: mock-all
