FROM golang:1.26.6-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/candidate .

FROM alpine:3.22
RUN apk add --no-cache ca-certificates
COPY --from=build /out/candidate /candidate
USER 10001
EXPOSE 8080
ENTRYPOINT ["/candidate"]
