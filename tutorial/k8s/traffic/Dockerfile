# The tutorial traffic driver (the Go one, which every port shares the
# sequence with) as an image for the in-cluster Job.
# Build context is tutorial/: docker build -f k8s/traffic/Dockerfile .
FROM golang:1.26.6-alpine AS build
WORKDIR /src
COPY go/go.mod go/go.sum ./
RUN go mod download
COPY go/ .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/traffic ./cmd/traffic

FROM alpine:3.22
RUN adduser -D -u 10001 app
USER app
COPY --from=build /out/traffic /usr/local/bin/traffic
COPY contract/traffic.json /traffic.json
ENV TRAFFIC_FILE=/traffic.json
ENTRYPOINT ["traffic"]
