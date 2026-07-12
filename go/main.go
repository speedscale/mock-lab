// Command proxymock-demo is the quickstart sample app. It exposes a small HTTP API
// on :8080 and fulfills each request by calling a downstream CNCF API. In the
// quickstart that downstream is https://demo-api.trafficreplay.com; proxymock
// records those calls, then mocks them so the app runs with no network at all.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

var downstream string

// emitTelemetry is the opt-in telemetry beacon (EMIT_TELEMETRY=1): every
// downstream-backed API request additionally POSTs a tracking event with a
// fresh event id in the URL path and a timestamp in the body. Both values
// change on every call, so replaying a recording produces mock misses on
// /v1/track/{event_id} — the raw material for the mock match-rate tuning
// demo. Off by default so the quickstart's recordings and the committed lab
// traffic are unchanged. Fire-and-forget: failures (e.g. a downstream without
// the /v1/track route) are ignored and never affect the caller's response.
var emitTelemetry = os.Getenv("EMIT_TELEMETRY") != ""

func trackEvent(path string) {
	if !emitTelemetry {
		return
	}
	// UUID-shaped event id so tooling classifies the rotating segment.
	h := randID("", 16)
	eventID := fmt.Sprintf("%s-%s-%s-%s-%s", h[0:8], h[8:12], h[12:16], h[16:20], h[20:32])

	body, _ := json.Marshal(map[string]string{
		"event": "api_request",
		"path":  path,
		"ts":    time.Now().UTC().Format(time.RFC3339),
	})
	resp, err := http.Post(downstream+"/v1/track/"+eventID, "application/json", bytes.NewReader(body))
	if err != nil {
		return
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	trackTimed(path)
}

// trackTimed is the time-anchored companion to the UUID beacon: it fires a second
// tracking call whose rotating ids all carry an embedded timestamp — a ULID in
// the path segment, and a bare unix epoch plus a Snowflake as query params. All
// three change on every call, so replaying a recording misses on them too. They
// exercise the patterns the mock match-rate tuner learns to mask beyond rotating
// UUIDs: a base32 id segment the plain id heuristic overlooks, and integer values
// (epoch, Snowflake) that are only distinguishable from ordinary numbers because
// their decoded time lands in the recording's own capture window. Same
// EMIT_TELEMETRY gate, same fire-and-forget contract.
func trackTimed(path string) {
	now := time.Now()
	body, _ := json.Marshal(map[string]string{
		"event": "api_request_timed",
		"path":  path,
	})
	url := fmt.Sprintf("%s/v1/track/%s?ts=%d&sid=%d", downstream, newULID(now), now.Unix(), newSnowflake(now))
	resp, err := http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
}

// crockford is the ULID / Crockford base32 alphabet (no I, L, O, U).
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// newULID builds a 26-char ULID: the first 10 chars encode now's 48-bit
// millisecond timestamp (Crockford base32, most-significant first) and the rest
// are random — the standard ULID layout, so the id sorts by time and decodes back
// to now.
func newULID(now time.Time) string {
	ms := now.UnixMilli()
	var out [26]byte
	for i := 9; i >= 0; i-- {
		out[i] = crockford[ms&0x1f]
		ms >>= 5
	}
	var r [16]byte
	_, _ = rand.Read(r[:])
	for i := 10; i < 26; i++ {
		out[i] = crockford[int(r[i-10])&0x1f]
	}
	return string(out[:])
}

// discordEpochMillis is the Discord Snowflake epoch (2015-01-01); a Snowflake
// packs milliseconds-since-epoch in its high 42 bits, so newSnowflake decodes
// back to now.
const discordEpochMillis = 1420070400000

func newSnowflake(now time.Time) uint64 {
	var r [2]byte
	_, _ = rand.Read(r[:])
	seq := uint64(r[0])<<8 | uint64(r[1])
	return uint64(now.UnixMilli()-discordEpochMillis)<<22 | (seq & 0x3fffff)
}

// In-memory auth + order state. The access_token and order_id are the two unique
// IDs that "move around": a fresh token comes from POST /oauth/token and rides in
// the Authorization header; a fresh order_id comes from POST /api/orders and rides
// in the GET /api/orders/{id} path. On replay both are regenerated, so proxymock's
// smart replace has to chain them from the responses into the later requests.
var (
	mu          sync.Mutex
	validTokens = map[string]bool{}
	orders      = map[string]order{}
)

type order struct {
	OrderID string `json:"order_id"`
	Project string `json:"project"`
	Status  string `json:"status"`
	Created string `json:"created"`
}

func randID(prefix string, n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

func main() {
	downstream = os.Getenv("DOWNSTREAM_URL")
	if downstream == "" {
		downstream = "https://demo-api.trafficreplay.com"
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", rootHandler)
	mux.HandleFunc("GET /api/projects", func(w http.ResponseWriter, r *http.Request) {
		trackEvent(r.URL.Path)
		fetch(w, "/v1/projects")
	})
	mux.HandleFunc("GET /api/projects/{id}", func(w http.ResponseWriter, r *http.Request) {
		trackEvent(r.URL.Path)
		fetch(w, "/v1/project/"+r.PathValue("id"))
	})
	mux.HandleFunc("GET /api/categories", func(w http.ResponseWriter, r *http.Request) {
		trackEvent(r.URL.Path)
		fetch(w, "/v1/categories")
	})
	mux.HandleFunc("GET /api/stats", func(w http.ResponseWriter, r *http.Request) {
		trackEvent(r.URL.Path)
		statsHandler(w, r)
	})

	// OAuth handshake + order flow — the two moving IDs (token, order_id).
	mux.HandleFunc("POST /oauth/token", tokenHandler)
	mux.HandleFunc("POST /api/orders", createOrderHandler)
	mux.HandleFunc("GET /api/orders/{id}", getOrderHandler)

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

// tokenHandler issues a fresh bearer token (moving ID #1).
func tokenHandler(w http.ResponseWriter, r *http.Request) {
	token := randID("", 32)
	mu.Lock()
	validTokens[token] = true
	mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"access_token": token,
		"token_type":   "Bearer",
		"expires_in":   3600,
	})
}

// authed reports whether the request carries a valid bearer token.
func authed(r *http.Request) bool {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return false
	}
	mu.Lock()
	defer mu.Unlock()
	return validTokens[strings.TrimPrefix(h, "Bearer ")]
}

// createOrderHandler validates the requested project against the downstream, then
// creates an order with a fresh order_id (moving ID #2). Requires a bearer token.
func createOrderHandler(w http.ResponseWriter, r *http.Request) {
	if !authed(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "missing or invalid bearer token"})
		return
	}
	var req struct {
		Project string `json:"project"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Project == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "project is required"})
		return
	}
	// Validate the project exists by calling the downstream (outbound — proxymock-mockable).
	resp, err := http.Get(downstream + "/v1/project/" + req.Project)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "unknown project", "project": req.Project})
		return
	}
	o := order{
		OrderID: randID("order-", 8),
		Project: req.Project,
		Status:  "created",
		Created: time.Now().UTC().Format(time.RFC3339),
	}
	mu.Lock()
	orders[o.OrderID] = o
	mu.Unlock()
	writeJSON(w, http.StatusCreated, o)
}

// getOrderHandler returns an order by ID. Requires a bearer token.
func getOrderHandler(w http.ResponseWriter, r *http.Request) {
	if !authed(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "missing or invalid bearer token"})
		return
	}
	mu.Lock()
	o, ok := orders[r.PathValue("id")]
	mu.Unlock()
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "order not found", "order_id": r.PathValue("id")})
		return
	}
	writeJSON(w, http.StatusOK, o)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}
