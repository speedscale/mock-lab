// Command server is the reference implementation of the CNCF demo API that runs,
// as a static export, behind https://demo-api.trafficreplay.com. The quickstart
// user never runs this — it exists so you can see the contract and regenerate the
// static dataset. Responses are deterministic so committed recordings stay valid.
package main

import (
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

//go:embed data/projects.json
var projectsJSON []byte

// Project is one CNCF landscape entry. The dataset is a frozen snapshot and may
// not reflect a project's current maturity or star count.
type Project struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Maturity    string `json:"maturity"`
	Category    string `json:"category"`
	Subcategory string `json:"subcategory,omitempty"`
	Description string `json:"description"`
	Repo        string `json:"repo"`
	Stars       int    `json:"stars"`
	License     string `json:"license"`
	Accepted    string `json:"accepted"`
	Website     string `json:"website,omitempty"`
}

var (
	projects []Project
	byID     map[string]Project
)

type categoryCount struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

func categories() []categoryCount {
	counts := map[string]int{}
	for _, p := range projects {
		counts[p.Category]++
	}
	out := []categoryCount{}
	for name, count := range counts {
		out = append(out, categoryCount{name, count})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func byMaturity(level string) []Project {
	level = strings.ToLower(level)
	out := []Project{}
	for _, p := range projects {
		if strings.ToLower(p.Maturity) == level {
			out = append(out, p)
		}
	}
	return out
}

func main() {
	exportDir := flag.String("export", "", "render the static JSON tree to this directory and exit (for S3/CloudFront)")
	flag.Parse()

	if err := json.Unmarshal(projectsJSON, &projects); err != nil {
		log.Fatalf("parse data: %v", err)
	}
	byID = make(map[string]Project, len(projects))
	for _, p := range projects {
		byID[p.ID] = p
	}

	if *exportDir != "" {
		if err := exportStatic(*exportDir); err != nil {
			log.Fatalf("export: %v", err)
		}
		return
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8090"
	}
	projectsDelay := durationFromEnv("PROJECTS_DELAY")

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /v1/projects", func(w http.ResponseWriter, r *http.Request) {
		if projectsDelay > 0 {
			time.Sleep(projectsDelay)
		}
		writeJSON(w, projects)
	})
	mux.HandleFunc("GET /v1/project/{id}", func(w http.ResponseWriter, r *http.Request) {
		p, ok := byID[r.PathValue("id")]
		if !ok {
			http.Error(w, `{"error":"not found"}`, http.StatusNotFound)
			return
		}
		writeJSON(w, p)
	})
	mux.HandleFunc("GET /v1/maturity/{level}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, byMaturity(r.PathValue("level")))
	})
	mux.HandleFunc("GET /v1/categories", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, categories())
	})
	// Telemetry sink for the demo apps' opt-in beacon (EMIT_TELEMETRY=1).
	// Acknowledges and discards; deterministic body so recordings stay valid.
	mux.HandleFunc("POST /v1/track/{id}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"tracked": true})
	})
	// GraphQL sink for the beacon's rotating-variable demo: the app POSTs a fixed
	// operation (operationName + query) whose variables.id rotates every run. The
	// tuner masks only the variable, never the operation identity — every GraphQL
	// call shares this one URL. Deterministic body shaped like the operation's
	// selection set so recordings stay valid. Only the opt-in beacon hits this.
	mux.HandleFunc("POST /graphql", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"data": map[string]any{"event": map[string]any{"ok": true}},
		})
	})
	// Cursor feed for the correlation/provenance demo: each call hands back a fresh
	// opaque nextCursor, so a client that pages with it produces a rotating
	// response→request value — a correlation to bind, not noise to mask. Accepts
	// ?cursor= and ignores it (the payload is a stub; only the rotating cursor
	// matters). Only the opt-in beacon hits this, so committed recordings are
	// unaffected.
	mux.HandleFunc("GET /v1/feed", func(w http.ResponseWriter, r *http.Request) {
		var c [16]byte
		_, _ = rand.Read(c[:])
		writeJSON(w, map[string]any{
			"items":      []string{"cncf-1", "cncf-2", "cncf-3"},
			"nextCursor": hex.EncodeToString(c[:]),
		})
	})
	// Stateful job poll for the sequenced-mock demo: the SAME request (fixed URL,
	// no query, no body) is answered with a different status each call, cycling
	// pending→running→done. A mock keys on the request signature, so it can only
	// replay one of these — the tuner flags /v1/job/status as a stateful endpoint
	// that needs a sequenced mock, not a masking fix. Only the opt-in beacon hits
	// it, so committed recordings are unaffected.
	var jobMu sync.Mutex
	jobStates := []string{"pending", "running", "done"}
	jobN := 0
	// Stable endpoint for the chaos demo. Unlike every other beacon route, nothing
	// here rotates: the SKU is fixed and the body is constant, so a replay is a
	// reliable cache HIT. Chaos perturbs a matched response, so the endpoint has
	// to match before there is anything to perturb — a rotating value would
	// produce misses and hide the effect being demonstrated.
	mux.HandleFunc("GET /v1/inventory/{sku}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"sku":       r.PathValue("sku"),
			"inStock":   true,
			"warehouse": "us-east",
			"quantity":  42,
		})
	})
	mux.HandleFunc("GET /v1/job/status", func(w http.ResponseWriter, r *http.Request) {
		jobMu.Lock()
		s := jobStates[jobN%len(jobStates)]
		jobN++
		jobMu.Unlock()
		// status is the substantive field (a few values over many polls → low
		// volatility → keeps the endpoint stateful); checkedAt rotates every call
		// (unique → high volatility → the differential probe flags it as noise the
		// mock can ignore, separated from the real state change).
		writeJSON(w, map[string]any{
			"job":       "cncf-report",
			"status":    s,
			"checkedAt": time.Now().UTC().Format(time.RFC3339Nano),
		})
	})
	// Purely-noisy endpoint for the differential-probe demo: the SAME request is
	// answered with a body that differs ONLY in a rotating timestamp. A whole-body
	// comparison would wrongly call this stateful; the field-level probe discounts
	// the volatile `now` leaf and leaves the endpoint correctly unflagged, listing
	// `now` as an observed-volatile response field instead.
	mux.HandleFunc("GET /v1/time", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{
			"region": "lab",
			"now":    time.Now().UTC().Format(time.RFC3339Nano),
		})
	})
	// Create→use demo: POST mints a fresh order id (returned in the Location header
	// and the body) and the client then GETs /v1/orders/{that id}. The id rotates
	// every run, so the GET is a mock miss — but it's a CREATED id, not free noise:
	// the tuner must NOT wildcard /v1/orders/* (that would match ids never issued),
	// it recognizes the create→use chain instead. Only the opt-in beacon hits these.
	mux.HandleFunc("POST /v1/orders", func(w http.ResponseWriter, r *http.Request) {
		id := newOrderID()
		w.Header().Set("Location", "/v1/orders/"+id)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]any{"id": id, "status": "created"})
	})
	mux.HandleFunc("GET /v1/orders/{id}", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"id": r.PathValue("id"), "status": "open", "items": []string{"cncf-1", "cncf-2"}})
	})
	// Auth/session demo (S-12418): mint a fresh access token AND a rotated session
	// cookie, then the client replays both in headers on GET /v1/me. Tokens rotate
	// every run, but they ride in headers — outside the mock signature — so they
	// never cause a mock miss; the tuner surfaces them as credentials to correlate
	// for a validating replay, not as a mask. Only the opt-in beacon hits these.
	mux.HandleFunc("POST /v1/auth/token", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Set-Cookie", "SESSIONID="+newOrderID()+"; Path=/; HttpOnly")
		writeJSON(w, map[string]any{"access_token": newOrderID(), "token_type": "Bearer", "expires_in": 3600})
	})
	mux.HandleFunc("GET /v1/me", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"user": "cncf-bot", "plan": "oss"})
	})

	log.Printf("CNCF reference API listening on :%s (%d projects, projects delay %s)", port, len(projects), projectsDelay)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func durationFromEnv(name string) time.Duration {
	value := os.Getenv(name)
	if value == "" {
		return 0
	}
	duration, err := time.ParseDuration(value)
	if err != nil || duration < 0 {
		log.Fatalf("%s must be a non-negative Go duration: %q", name, value)
	}
	return duration
}

// newOrderID mints a fresh UUID-shaped order id, so tooling reads the path segment
// as a rotating id (not a literal) — the create→use demo needs it to rotate.
func newOrderID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// exportStatic renders every endpoint to a flat file tree that mirrors the URL
// paths, ready to `aws s3 sync` behind CloudFront. Path-only routes (no query
// strings) keep the static origin dumb.
func exportStatic(dir string) error {
	write := func(urlPath string, v any) error {
		out := filepath.Join(dir, filepath.FromSlash(urlPath))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		b, err := json.MarshalIndent(v, "", "  ")
		if err != nil {
			return err
		}
		log.Printf("  %s", urlPath)
		return os.WriteFile(out, append(b, '\n'), 0o644)
	}

	if err := write("v1/projects", projects); err != nil {
		return err
	}
	for _, p := range projects {
		if err := write("v1/project/"+p.ID, p); err != nil {
			return err
		}
	}
	if err := write("v1/categories", categories()); err != nil {
		return err
	}
	for _, level := range []string{"graduated", "incubating", "sandbox"} {
		if err := write("v1/maturity/"+level, byMaturity(level)); err != nil {
			return err
		}
	}
	if err := write("healthz", map[string]string{"status": "ok"}); err != nil {
		return err
	}
	// Landing object served at / (CloudFront default_root_object) and the body for
	// 403/404 (CloudFront custom_error_response), so a browser hitting the root or a
	// bad path gets readable JSON instead of an S3 "Access Denied".
	if err := write("index.json", map[string]any{
		"service":     "proxymock CNCF demo API",
		"description": "Static demo downstream for the proxymock quickstart.",
		"docs":        "https://docs.speedscale.com/proxymock/",
		"endpoints":   []string{"/v1/projects", "/v1/project/{id}", "/v1/categories", "/v1/maturity/{graduated|incubating|sandbox}", "/healthz"},
	}); err != nil {
		return err
	}
	if err := write("404.json", map[string]string{
		"error": "not found",
		"hint":  "see / for the list of available endpoints",
	}); err != nil {
		return err
	}
	log.Printf("exported static tree to %s", dir)
	return nil
}
