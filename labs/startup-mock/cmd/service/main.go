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
	query := os.Getenv("STARTUP_QUERY")
	if query == "" {
		query = "environment=lab"
	}
	endpoint := "http://localhost:18090/bootstrap/config?" + query
	client := &http.Client{
		Timeout:   5 * time.Second,
		Transport: &http.Transport{Proxy: proxyIncludingLoopback},
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

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ready")
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:18080", mux))
}

// The standard proxy helper bypasses loopback, which hides the local dependency from proxymock.
func proxyIncludingLoopback(request *http.Request) (*url.URL, error) {
	for _, key := range []string{strings.ToUpper(request.URL.Scheme) + "_PROXY", strings.ToLower(request.URL.Scheme) + "_proxy"} {
		if value := os.Getenv(key); value != "" {
			return url.Parse(value)
		}
	}
	return nil, nil
}
