FROM golang:1.23.12-alpine3.22 AS catalog-build

WORKDIR /src
COPY go/go.mod ./go.mod
COPY go/main.go ./main.go
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/catalog-api .

FROM golang:1.23.12-alpine3.22 AS fixture-build

WORKDIR /src
COPY shared/server/go.mod ./go.mod
COPY shared/server/main.go ./main.go
COPY shared/server/data ./data
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/catalog-fixture .

FROM scratch
COPY --from=catalog-build /out/catalog-api /catalog-api
COPY --from=fixture-build /out/catalog-fixture /catalog-fixture
USER 65532:65532
ENTRYPOINT ["/catalog-api"]
