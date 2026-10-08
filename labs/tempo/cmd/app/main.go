package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/speedscale/mock-lab/tempo-demo/internal/catalog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.30.0"
)

const (
	maxRequestBytes = 64 << 10
	maxProductIDs   = 20
)

type catalogRequest struct {
	ProductIDs []string `json:"product_ids"`
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tracerProvider, err := newTracerProvider(ctx, envOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317"))
	if err != nil {
		log.Fatalf("configure tracing: %v", err)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tracerProvider.Shutdown(shutdownCtx); err != nil {
			log.Printf("flush tracing: %v", err)
		}
	}()

	transport := otelhttp.NewTransport(
		&http.Transport{Proxy: proxyFromEnvironmentIncludingLocalhost},
		otelhttp.WithSpanNameFormatter(func(_ string, _ *http.Request) string {
			return "GET inventory"
		}),
	)
	client := &http.Client{Timeout: 5 * time.Second, Transport: transport}
	service, err := catalog.NewService(
		client,
		envOrDefault("INVENTORY_URL", "http://localhost:8090"),
		otel.Tracer("github.com/speedscale/mock-lab/tempo-demo/internal/catalog"),
	)
	if err != nil {
		log.Fatalf("configure catalog service: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("POST /api/catalog", catalogHandler(service))

	handler := otelhttp.NewHandler(mux, "catalog-api", otelhttp.WithSpanNameFormatter(
		func(_ string, r *http.Request) string { return r.Method + " " + r.URL.Path },
	))
	server := &http.Server{
		Addr:              envOrDefault("APP_ADDR", ":8080"),
		Handler:           handler,
		ReadHeaderTimeout: 2 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown server: %v", err)
		}
	}()

	log.Printf("catalog API listening on %s", server.Addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func catalogHandler(service *catalog.Service) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		request, err := decodeCatalogRequest(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		result, err := service.Build(r.Context(), request.ProductIDs)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(result); err != nil {
			log.Printf("encode response: %v", err)
		}
	}
}

func decodeCatalogRequest(body io.Reader) (catalogRequest, error) {
	decoder := json.NewDecoder(io.LimitReader(body, maxRequestBytes))
	decoder.DisallowUnknownFields()
	var request catalogRequest
	if err := decoder.Decode(&request); err != nil {
		return catalogRequest{}, fmt.Errorf("decode request: %w", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return catalogRequest{}, fmt.Errorf("decode request: expected one JSON object")
	}
	if len(request.ProductIDs) == 0 || len(request.ProductIDs) > maxProductIDs {
		return catalogRequest{}, fmt.Errorf("product_ids must contain 1 to %d values", maxProductIDs)
	}

	seen := make(map[string]struct{}, len(request.ProductIDs))
	for i, productID := range request.ProductIDs {
		if strings.TrimSpace(productID) == "" {
			return catalogRequest{}, fmt.Errorf("product_ids[%d] must not be blank", i)
		}
		if _, duplicate := seen[productID]; duplicate {
			return catalogRequest{}, fmt.Errorf("product_ids[%d] duplicates %q", i, productID)
		}
		seen[productID] = struct{}{}
	}
	return request, nil
}

func newTracerProvider(ctx context.Context, endpoint string) (*sdktrace.TracerProvider, error) {
	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(endpoint), otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	serviceResource, err := resource.New(ctx, resource.WithAttributes(semconv.ServiceName("catalog-api")))
	if err != nil {
		return nil, err
	}
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter, sdktrace.WithBatchTimeout(100*time.Millisecond)),
		sdktrace.WithResource(serviceResource),
	)
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))
	return provider, nil
}

// net/http bypasses proxies for localhost. proxymock is a local proxy, so the
// lab reads the injected proxy variables directly for dependency calls.
func proxyFromEnvironmentIncludingLocalhost(request *http.Request) (*url.URL, error) {
	proxyAddress := firstNonEmpty(
		os.Getenv(strings.ToUpper(request.URL.Scheme)+"_PROXY"),
		os.Getenv(strings.ToLower(request.URL.Scheme)+"_proxy"),
		os.Getenv("ALL_PROXY"),
		os.Getenv("all_proxy"),
	)
	if proxyAddress == "" {
		return nil, nil
	}
	return url.Parse(proxyAddress)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
