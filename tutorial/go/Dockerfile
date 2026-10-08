# Build context is this directory: docker build -t tutorial-orders-go .
FROM golang:1.26.6-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Keep the symbol table: Speedscale's eBPF capture (nettap) finds Go's
# network and TLS functions by name, so a stripped (-s -w) binary is invisible
# to it in the cluster tutorial.
RUN CGO_ENABLED=0 go build -trimpath -o /out/tutorial-orders .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 app
USER app
COPY --from=build /out/tutorial-orders /usr/local/bin/tutorial-orders
EXPOSE 8080
ENTRYPOINT ["tutorial-orders"]
