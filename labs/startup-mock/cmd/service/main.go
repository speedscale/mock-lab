package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

func main() {
	backend := os.Getenv("BACKEND_URL")
	if backend == "" {
		backend = "http://localhost:8090"
	}
	query := os.Getenv("STARTUP_QUERY")
	if query == "" {
		query = "watch=true"
	}
	endpoint := backend + "/api/v1/buckets/demo/values?" + query

	client := &http.Client{
		Timeout:   5 * time.Second,
		Transport: &http.Transport{Proxy: proxyIncludingLocalhost},
	}
	response, err := client.Get(endpoint)
	if err != nil {
		log.Fatalf("startup dependency call failed: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(response.Body)
		log.Fatalf("startup dependency returned %s: %s", response.Status, strings.TrimSpace(string(body)))
	}
	log.Printf("startup dependency matched: %s", endpoint)

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ready")
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

// Go's default proxy helper bypasses loopback, so this lab checks the proxy variables directly.
func proxyIncludingLocalhost(request *http.Request) (*url.URL, error) {
	for _, key := range []string{strings.ToUpper(request.URL.Scheme) + "_PROXY", strings.ToLower(request.URL.Scheme) + "_proxy"} {
		if value := os.Getenv(key); value != "" {
			return url.Parse(value)
		}
	}
	return nil, nil
}
