package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	_ "net/http/pprof"
	"net/url"
	"os"
	"runtime/pprof"
	"strings"
	"time"

	"github.com/speedscale/mock-lab/pyroscope-demo/internal/stats"
)

const maxCatalogResponseBytes = 16 << 20

type catalogResponse struct {
	Projects []stats.Project `json:"projects"`
}

func main() {
	appAddress := envOrDefault("APP_ADDR", ":8080")
	pprofAddress := envOrDefault("PPROF_ADDR", ":6060")
	downstreamURL := envOrDefault("DOWNSTREAM_URL", "http://localhost:8090")

	client := &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			Proxy: proxyFromEnvironmentIncludingLocalhost,
		},
	}

	go func() {
		log.Printf("pprof listening on %s", pprofAddress)
		if err := http.ListenAndServe(pprofAddress, http.DefaultServeMux); err != nil {
			log.Fatalf("pprof server: %v", err)
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /api/catalog/stats", func(w http.ResponseWriter, r *http.Request) {
		labels := pprof.Labels("endpoint", "catalog_stats")
		pprof.Do(r.Context(), labels, func(ctx context.Context) {
			result, err := fetchAndBuild(ctx, client, downstreamURL+"/v1/catalog")
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadGateway)
				return
			}

			w.Header().Set("Content-Type", "application/json")
			if err := json.NewEncoder(w).Encode(result); err != nil {
				log.Printf("encode response: %v", err)
			}
		})
	})

	log.Printf("catalog API listening on %s; downstream=%s", appAddress, downstreamURL)
	log.Fatal(http.ListenAndServe(appAddress, mux))
}

func fetchAndBuild(ctx context.Context, client *http.Client, endpoint string) (stats.Result, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return stats.Result{}, fmt.Errorf("build downstream request: %w", err)
	}

	response, err := client.Do(req)
	if err != nil {
		return stats.Result{}, fmt.Errorf("fetch catalog: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		return stats.Result{}, fmt.Errorf("catalog returned %s", response.Status)
	}

	var payload catalogResponse
	limited := io.LimitReader(response.Body, maxCatalogResponseBytes)
	if err := json.NewDecoder(limited).Decode(&payload); err != nil {
		return stats.Result{}, fmt.Errorf("decode catalog: %w", err)
	}

	return stats.Build(payload.Projects), nil
}

// net/http intentionally bypasses proxies for localhost. proxymock is a local
// proxy, so this transport reads the injected proxy variables directly.
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
