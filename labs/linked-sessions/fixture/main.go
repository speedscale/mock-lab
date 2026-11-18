// The fixture stands in for the payment and order services while a recording
// is captured. Mocked runs never start it.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"sync"
)

type payment struct {
	ID          string `json:"paymentId"`
	Status      string `json:"status"`
	AmountCents int64  `json:"amount_cents"`
}

func main() {
	var (
		mu       sync.Mutex
		payments = map[string]payment{}
	)

	pay := http.NewServeMux()
	pay.HandleFunc("GET /healthz", ok)
	pay.HandleFunc("POST /v1/payments", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing service token"})
			return
		}
		var req struct {
			AmountCents int64 `json:"amount_cents"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		p := payment{ID: "pay-" + randomHex(4), Status: "captured", AmountCents: req.AmountCents}
		mu.Lock()
		payments[p.ID] = p
		mu.Unlock()
		writeJSON(w, http.StatusCreated, p)
	})
	pay.HandleFunc("GET /v1/payments/{id}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		p, found := payments[r.PathValue("id")]
		mu.Unlock()
		if !found {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown payment"})
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	orders := http.NewServeMux()
	orders.HandleFunc("GET /healthz", ok)
	orders.HandleFunc("GET /v1/orders", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing partner token"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"orders": []map[string]any{
			{"order": "ord-" + randomHex(4), "status": "shipped"},
		}})
	})

	go func() { log.Fatal(http.ListenAndServe("localhost:8092", orders)) }()
	log.Printf("payments on :8091, orders on :8092")
	log.Fatal(http.ListenAndServe("localhost:8091", pay))
}

func ok(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
