package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// readinessFixture adds opt-in business behavior without changing the tutorial contract.
type readinessFixture struct {
	pool        *pgxpool.Pool
	upstream    string
	client      *http.Client
	mu          sync.Mutex
	failures    int
	openUntil   time.Time
	cache       string
	cacheUntil  time.Time
	work        chan struct{}
	requests    atomic.Uint64
	started     time.Time
	logs        *log.Logger
	leak        []byte
	initialized atomic.Bool
}

func defect(id string) bool { return os.Getenv("READINESS_DEFECT") == id }

func newReadinessFixture(pool *pgxpool.Pool, upstream string) (*readinessFixture, error) {
	f := &readinessFixture{pool: pool, upstream: upstream, client: &http.Client{Timeout: 100 * time.Millisecond}, work: make(chan struct{}, 2), started: time.Now(), logs: log.Default()}
	if path := os.Getenv("READINESS_LOG"); path != "" {
		out, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			return nil, err
		}
		f.logs = log.New(out, "", 0)
	}
	if defect("R19") {
		f.leak = make([]byte, 256<<20)
		for i := range f.leak {
			f.leak[i] = 1
		}
	}
	go func() {
		time.Sleep(750 * time.Millisecond)
		var quantity int
		if pool.QueryRow(context.Background(), "SELECT quantity FROM readiness_inventory WHERE id=1").Scan(&quantity) == nil {
			f.initialized.Store(true)
		}
	}()
	return f, nil
}

func (f *readinessFixture) handler(original http.Handler) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /ready/readyz", f.ready)
	mux.HandleFunc("GET /ready/critical", f.critical)
	mux.HandleFunc("POST /ready/orders", f.create)
	mux.HandleFunc("GET /ready/orders/{id}", f.get)
	mux.HandleFunc("POST /ready/reserve", f.reserve)
	mux.HandleFunc("GET /ready/optional", f.optional)
	mux.HandleFunc("GET /ready/freshness", f.freshness)
	mux.HandleFunc("GET /ready/session", f.session)
	mux.HandleFunc("GET /ready/work", f.load)
	mux.HandleFunc("GET /ready/runtime", func(w http.ResponseWriter, r *http.Request) {
		if env("READINESS_VARIANT", "one") == "two" && defect("R25") {
			writeError(w, 500, "incompatible variant")
			return
		}
		writeJSON(w, 200, map[string]any{"runtime": runtime.Version(), "variant": env("READINESS_VARIANT", "one")})
	})
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if defect("R03") && r.URL.Path == "/catalog" {
			writeJSON(w, 200, map[string]any{"products": []any{}})
			return
		}
		original.ServeHTTP(w, r)
	}))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if time.Since(f.started) < 750*time.Millisecond && r.URL.Path != "/ready/readyz" && !defect("R22") {
			writeError(w, 503, "not ready")
			return
		}
		if defect("R14") {
			time.Sleep(250 * time.Millisecond)
		}
		id := r.Header.Get("X-Request-Id")
		if id == "" {
			id = uuid.NewString()
		}
		if !defect("R28") {
			w.Header().Set("X-Request-Id", id)
		}
		started := time.Now()
		capture := &statusWriter{ResponseWriter: w, status: 200}
		mux.ServeHTTP(capture, r)
		entry := map[string]any{"request_id": id, "path": r.URL.Path, "status": capture.status, "duration_ms": time.Since(started).Milliseconds(), "at": time.Now().UTC().Format(time.RFC3339Nano)}
		if capture.status >= 500 || capture.Header().Get("X-Dependency-Fault") == "true" {
			entry["fault"] = "dependency_unavailable"
		}
		if defect("R28") {
			delete(entry, "request_id")
			delete(entry, "fault")
		}
		if defect("R27") {
			entry["secret"] = r.Header.Get("X-Synthetic-Secret")
		}
		raw, _ := json.Marshal(entry)
		f.logs.Print(string(raw))
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}
func (f *readinessFixture) ready(w http.ResponseWriter, r *http.Request) {
	if !defect("R22") {
		if !f.initialized.Load() || f.pool.Ping(r.Context()) != nil {
			writeError(w, 503, "not ready")
			return
		}
	}
	writeJSON(w, 200, map[string]any{"ready": true})
}
func (f *readinessFixture) critical(w http.ResponseWriter, r *http.Request) {
	if !f.initialized.Load() {
		writeError(w, 503, "not initialized")
		return
	}
	if defect("R15") {
		f.mu.Lock()
		defer f.mu.Unlock()
		time.Sleep(75 * time.Millisecond)
	}
	if defect("R06") && f.requests.Add(1)%10 == 0 {
		writeError(w, 500, "unexpected business failure")
		return
	}
	var value int
	if err := f.pool.QueryRow(r.Context(), "SELECT quantity FROM readiness_inventory WHERE id=1").Scan(&value); err != nil {
		writeError(w, 503, "database unavailable")
		return
	}
	writeJSON(w, 200, map[string]any{"status": "ok", "inventory": value})
}
func fixtureIdentity(r *http.Request) (tenant, actor string, ok bool) {
	switch r.Header.Get("Authorization") {
	case "Bearer fixture-a":
		return "tenant-a", "actor-a", true
	case "Bearer fixture-b":
		return "tenant-b", "actor-b", true
	default:
		if defect("R26") {
			return "tenant-a", "unknown", true
		}
		return "", "", false
	}
}

type fixtureOrder struct {
	WorkMS   int    `json:"work_ms"`
	Key      string `json:"key"`
	Quantity int    `json:"quantity"`
	Secret   string `json:"secret"`
}

func (f *readinessFixture) create(w http.ResponseWriter, r *http.Request) {
	tenant, actor, ok := fixtureIdentity(r)
	if !ok {
		writeError(w, 401, "unauthorized")
		return
	}
	var order fixtureOrder
	if err := json.NewDecoder(io.LimitReader(r.Body, 4096)).Decode(&order); err != nil || order.Key == "" || order.Quantity < 1 || order.Quantity > 99 {
		status := 400
		if defect("R05") {
			status = 500
		}
		writeError(w, status, "invalid order")
		return
	}
	if order.WorkMS > 0 && order.WorkMS <= 20000 {
		raw, _ := json.Marshal(map[string]any{"phase": "accepted", "request_id": r.Header.Get("X-Request-Id"), "key": order.Key, "at": time.Now().UTC().Format(time.RFC3339Nano)})
		f.logs.Print(string(raw))
		select {
		case <-time.After(time.Duration(order.WorkMS) * time.Millisecond):
		case <-r.Context().Done():
			return
		}
	}
	if defect("R10") {
		order.Key += "-" + uuid.NewString()
	}
	id := uuid.NewString()
	total := order.Quantity * 1200
	if defect("R04") {
		total++
	}
	tx, err := f.pool.Begin(r.Context())
	if err != nil {
		writeError(w, 503, "database unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var saved string
	err = tx.QueryRow(r.Context(), "INSERT INTO readiness_orders(id,tenant,business_key,quantity,total_cents) VALUES($1,$2,$3,$4,$5) ON CONFLICT(tenant,business_key) DO UPDATE SET business_key=EXCLUDED.business_key RETURNING id", id, tenant, order.Key, order.Quantity, total).Scan(&saved)
	if err == nil && saved == id && !defect("R29") {
		_, err = tx.Exec(r.Context(), "INSERT INTO readiness_audit(order_id,tenant,actor,action,outcome) VALUES($1,$2,$3,'create','success')", id, tenant, actor)
	}
	if err != nil || tx.Commit(r.Context()) != nil {
		writeError(w, 500, "order failed")
		return
	}
	result := map[string]any{"id": saved, "key": order.Key, "quantity": order.Quantity, "total_cents": total, "status": "placed"}
	if defect("R02") {
		delete(result, "total_cents")
	}
	if defect("R01") {
		result["status"] = "unknown"
	}
	if defect("R27") {
		result["secret"] = order.Secret
	}
	if order.Secret != "" {
		req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, f.upstream+"/v1/project/kubernetes", nil)
		req.Header.Set("X-Synthetic-Secret", "[REDACTED]")
		if defect("R27") {
			req.Header.Set("X-Synthetic-Secret", order.Secret)
		}
		req.Header.Set("X-Request-Id", r.Header.Get("X-Request-Id"))
		resp, err := f.client.Do(req)
		if err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
	}
	if r.URL.Query().Get("responseDelay") == "150" {
		time.Sleep(150 * time.Millisecond)
	}
	writeJSON(w, 201, result)
}
func (f *readinessFixture) get(w http.ResponseWriter, r *http.Request) {
	tenant, _, ok := fixtureIdentity(r)
	if !ok {
		writeError(w, 401, "unauthorized")
		return
	}
	var key string
	var quantity, total int
	sql := "SELECT business_key,quantity,total_cents FROM readiness_orders WHERE id=$1 AND tenant=$2"
	args := []any{r.PathValue("id"), tenant}
	if defect("R26") {
		sql = "SELECT business_key,quantity,total_cents FROM readiness_orders WHERE id=$1"
		args = args[:1]
	}
	err := f.pool.QueryRow(r.Context(), sql, args...).Scan(&key, &quantity, &total)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, 404, "order not found")
		return
	}
	if err != nil {
		writeError(w, 500, "read failed")
		return
	}
	writeJSON(w, 200, map[string]any{"id": r.PathValue("id"), "key": key, "quantity": quantity, "total_cents": total, "status": "placed"})
}
func (f *readinessFixture) reserve(w http.ResponseWriter, r *http.Request) {
	_, _, ok := fixtureIdentity(r)
	if !ok {
		writeError(w, 401, "unauthorized")
		return
	}
	sql := "UPDATE readiness_inventory SET quantity=quantity-1 WHERE id=1 AND quantity>0 RETURNING quantity"
	if defect("R11") {
		sql = "UPDATE readiness_inventory SET quantity=quantity-1 WHERE id=1 RETURNING quantity"
	}
	var left int
	err := f.pool.QueryRow(r.Context(), sql).Scan(&left)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, 409, "sold out")
		return
	}
	if err != nil {
		writeError(w, 500, "reservation failed")
		return
	}
	writeJSON(w, 200, map[string]any{"remaining": left})
}
func (f *readinessFixture) fetch(r *http.Request) (string, error) {
	f.mu.Lock()
	blocked := time.Now().Before(f.openUntil)
	f.mu.Unlock()
	if blocked {
		return "", errors.New("circuit open")
	}
	attempts := 2
	if defect("R07") {
		attempts = 4
	}
	for range attempts {
		timeout := 100 * time.Millisecond
		if defect("R07") {
			timeout = 400 * time.Millisecond
		}
		ctx, cancel := context.WithTimeout(r.Context(), timeout)
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, f.upstream+"/v1/projects", nil)
		req.Header.Set("X-Request-Id", r.Header.Get("X-Request-Id"))
		client := &http.Client{Timeout: timeout}
		resp, err := client.Do(req)
		var raw []byte
		if err == nil {
			raw, err = io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			if resp.StatusCode != 200 {
				err = fmt.Errorf("upstream status %d", resp.StatusCode)
			}
		}
		cancel()
		if err == nil {
			f.mu.Lock()
			f.failures = 0
			f.mu.Unlock()
			return string(raw), nil
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failures++
	if f.failures >= 3 && !defect("R07") {
		f.openUntil = time.Now().Add(300 * time.Millisecond)
		if defect("R09") {
			f.openUntil = time.Now().Add(time.Hour)
		}
	}
	return "", errors.New("dependency unavailable")
}
func (f *readinessFixture) optional(w http.ResponseWriter, r *http.Request) {
	value, err := f.fetch(r)
	if err != nil {
		w.Header().Set("X-Dependency-Fault", "true")
		if defect("R08") {
			writeError(w, 500, "optional dependency failed")
			return
		}
		writeJSON(w, 200, map[string]any{"source": "fallback", "products": []string{}})
		return
	}
	writeJSON(w, 200, map[string]any{"source": "upstream", "catalog": json.RawMessage(value)})
}
func (f *readinessFixture) freshness(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.cache == "" || (!defect("R13") && time.Now().After(f.cacheUntil)) {
		if err := f.pool.QueryRow(r.Context(), "SELECT version FROM readiness_catalog WHERE id=1").Scan(&f.cache); err != nil {
			writeError(w, 500, "cache refresh failed")
			return
		}
		f.cacheUntil = time.Now().Add(100 * time.Millisecond)
	}
	writeJSON(w, 200, map[string]any{"version": f.cache})
}
func (f *readinessFixture) session(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") == "Bearer expired-fixture" && !defect("R13") {
		writeError(w, 401, "expired")
		return
	}
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		writeError(w, 401, "unauthorized")
		return
	}
	writeJSON(w, 200, map[string]any{"authenticated": true})
}
func (f *readinessFixture) load(w http.ResponseWriter, r *http.Request) {
	if !defect("R17") {
		select {
		case f.work <- struct{}{}:
			defer func() { <-f.work }()
		default:
			writeError(w, 429, "overloaded")
			return
		}
	}
	select {
	case <-r.Context().Done():
		return
	case <-time.After(500 * time.Millisecond):
	}
	writeJSON(w, 200, map[string]any{"completed": true})
}
