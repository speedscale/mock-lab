// Command dashboard serves a local page that drives every demo endpoint.
// The page switches between the app on :8080 and proxymock's inbound proxy
// on :4143. Calls are relayed from this process so the browser stays on one
// origin, and so the Host header is "localhost" — the host the recordings key on.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

//go:embed static
var staticFS embed.FS

// upstreamBase overrides the target origin in tests. Empty means
// http://localhost:{port}, which is what a recording should capture.
var upstreamBase string

var client = &http.Client{
	Timeout: 8 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		return http.ErrUseLastResponse
	},
}

type relayRequest struct {
	Port   int    `json:"port"`
	Method string `json:"method"`
	Path   string `json:"path"`
	Body   string `json:"body,omitempty"`
	Token  string `json:"token,omitempty"`
}

type relayResult struct {
	Port      int    `json:"port"`
	Method    string `json:"method"`
	Path      string `json:"path"`
	Status    int    `json:"status"`
	ElapsedMs int64  `json:"elapsed_ms"`
	Body      string `json:"body"`
	Error     string `json:"error,omitempty"`
	Detail    string `json:"detail,omitempty"`
}

func main() {
	port := os.Getenv("DASHBOARD_PORT")
	if port == "" {
		port = "8091"
	}
	addr := "127.0.0.1:" + port
	log.Printf("dashboard http://%s", addr)
	log.Printf("calls go to localhost:8080 (app) or localhost:4143 (proxymock record)")
	log.Fatal(http.ListenAndServe(addr, newMux()))
}

func newMux() http.Handler {
	sub, err := fs.Sub(staticFS, "static")
	if err != nil {
		panic(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /relay", relayHandler)
	mux.Handle("/", http.FileServer(http.FS(sub)))
	return mux
}

func relayHandler(w http.ResponseWriter, r *http.Request) {
	var req relayRequest
	dec := json.NewDecoder(io.LimitReader(r.Body, 1<<16+512))
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, relayResult{Error: "bad_request", Detail: "The request was not valid JSON."})
		return
	}
	if err := validate(req); err != nil {
		writeJSON(w, http.StatusBadRequest, relayResult{Error: "bad_request", Detail: err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, forward(req))
}

func validate(req relayRequest) error {
	if req.Port != 8080 && req.Port != 4143 {
		return errors.New("Choose port 8080 or 4143.")
	}
	if req.Method != http.MethodGet && req.Method != http.MethodPost {
		return errors.New("Only GET and POST are used.")
	}
	if !allowed(req.Method, req.Path) {
		return errors.New("That path is not one of the demo calls.")
	}
	if len(req.Body) > 1<<16 {
		return errors.New("Body is too large.")
	}
	if req.Token != "" && !tokenOK(req.Token) {
		return errors.New("Token has unexpected characters.")
	}
	return nil
}

func allowed(method, path string) bool {
	switch {
	case method == http.MethodGet && (path == "/" || path == "/api/projects" || path == "/api/categories" || path == "/api/stats"):
		return true
	case method == http.MethodGet && strings.HasPrefix(path, "/api/projects/"):
		return slug(strings.TrimPrefix(path, "/api/projects/"))
	case method == http.MethodGet && strings.HasPrefix(path, "/api/orders/"):
		return slug(strings.TrimPrefix(path, "/api/orders/"))
	case method == http.MethodPost && (path == "/oauth/token" || path == "/api/orders"):
		return true
	default:
		return false
	}
}

func slug(s string) bool {
	if s == "" || len(s) > 80 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

func tokenOK(s string) bool {
	if len(s) > 256 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case r == '.' || r == '_' || r == '~' || r == '+' || r == '/' || r == '-':
		default:
			return false
		}
	}
	return true
}

func forward(req relayRequest) relayResult {
	out := relayResult{Port: req.Port, Method: req.Method, Path: req.Path}
	var body io.Reader
	if req.Method == http.MethodPost {
		body = strings.NewReader(req.Body)
	}
	httpReq, err := http.NewRequest(req.Method, targetBase(req.Port)+req.Path, body)
	if err != nil {
		out.Error = "request_failed"
		out.Detail = "Could not build the request."
		return out
	}
	if req.Method == http.MethodPost && req.Body != "" {
		httpReq.Header.Set("Content-Type", "application/json")
	}
	if req.Token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+req.Token)
	}
	httpReq.Header.Set("User-Agent", "mock-lab-dashboard")

	start := time.Now()
	resp, err := client.Do(httpReq)
	out.ElapsedMs = time.Since(start).Milliseconds()
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) || isTimeout(err) {
			out.Error = "timeout"
			return out
		}
		out.Error = "unreachable"
		return out
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		out.Error = "request_failed"
		out.Detail = "The response stopped before it finished."
		return out
	}
	out.Status = resp.StatusCode
	out.Body = string(raw)
	return out
}

// targetBase is localhost, not 127.0.0.1, because recorded signatures key on
// the host as written. Tests point upstreamBase at an httptest server instead.
func targetBase(port int) string {
	if upstreamBase != "" {
		return upstreamBase
	}
	return fmt.Sprintf("http://localhost:%d", port)
}

func isTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}
