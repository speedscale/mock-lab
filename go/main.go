// Command proxymock-demo is the quickstart sample app. It exposes a small HTTP API
// on :8080 and fulfills each request by calling a downstream CNCF API. In the
// quickstart that downstream is https://demo-api-dev.trafficreplay.com; proxymock
// records those calls, then mocks them so the app runs with no network at all.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

var downstream string

func main() {
	downstream = os.Getenv("DOWNSTREAM_URL")
	if downstream == "" {
		downstream = "https://demo-api-dev.trafficreplay.com"
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", rootHandler)
	mux.HandleFunc("GET /api/projects", func(w http.ResponseWriter, r *http.Request) {
		fetch(w, "/v1/projects")
	})
	mux.HandleFunc("GET /api/projects/{id}", func(w http.ResponseWriter, r *http.Request) {
		fetch(w, "/v1/project/"+r.PathValue("id"))
	})
	mux.HandleFunc("GET /api/categories", func(w http.ResponseWriter, r *http.Request) {
		fetch(w, "/v1/categories")
	})
	mux.HandleFunc("GET /api/stats", statsHandler)

	log.Printf("Starting HTTP server on :%s (downstream=%s)", port, downstream)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func rootHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"service":    "proxymock-cncf-demo",
		"downstream": downstream,
		"ts":         time.Now().UTC().Format(time.RFC3339),
	})
}

// fetch proxies a GET to the downstream and streams the response back.
func fetch(w http.ResponseWriter, path string) {
	resp, err := http.Get(downstream + path)
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":%q,"hint":"downstream unreachable - try 'proxymock mock'"}`, err.Error()), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

// statsHandler shows the app doing real work on top of the downstream: it pulls
// the full project list and aggregates counts by maturity.
func statsHandler(w http.ResponseWriter, r *http.Request) {
	resp, err := http.Get(downstream + "/v1/projects")
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	var projects []map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&projects); err != nil {
		http.Error(w, `{"error":"bad downstream response"}`, http.StatusBadGateway)
		return
	}

	byMaturity := map[string]int{}
	for _, p := range projects {
		if m, ok := p["maturity"].(string); ok {
			byMaturity[m]++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"total":       len(projects),
		"by_maturity": byMaturity,
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}
