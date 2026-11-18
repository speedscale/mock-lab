// The fixture stands in for the catalog and the payment processor while a
// recording is captured. Mocked runs never start it.
package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
)

type product struct {
	SKU        string `json:"sku"`
	Name       string `json:"name"`
	PriceCents int64  `json:"price_cents"`
	InStock    bool   `json:"in_stock"`
}

var products = map[string]product{
	"SKU-1001": {"SKU-1001", "Trail mug", 1899, true},
	"SKU-2002": {"SKU-2002", "Rain shell", 12950, true},
	"SKU-3003": {"SKU-3003", "Wool socks", 1450, true},
	"SKU-4004": {"SKU-4004", "Headlamp", 3995, false},
}

func main() {
	catalog := http.NewServeMux()
	catalog.HandleFunc("GET /healthz", ok)
	catalog.HandleFunc("GET /v1/skus/{sku}", func(w http.ResponseWriter, r *http.Request) {
		p, found := products[r.PathValue("sku")]
		if !found {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"code": "sku_not_found"}})
			return
		}
		writeJSON(w, http.StatusOK, p)
	})

	payments := http.NewServeMux()
	payments.HandleFunc("GET /healthz", ok)
	payments.HandleFunc("POST /v1/charges", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			AmountCents int64  `json:"amount_cents"`
			Currency    string `json:"currency"`
			CardToken   string `json:"card_token"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		switch req.CardToken {
		case "tok_declined":
			writeJSON(w, http.StatusPaymentRequired, map[string]any{"error": map[string]any{"code": "card_declined", "decline_code": "insufficient_funds"}})
		case "tok_outage":
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"code": "processor_unavailable"}})
		default:
			id := make([]byte, 8)
			_, _ = rand.Read(id)
			writeJSON(w, http.StatusCreated, map[string]any{
				"id":           "ch_" + hex.EncodeToString(id),
				"status":       "succeeded",
				"amount_cents": req.AmountCents,
				"currency":     req.Currency,
			})
		}
	})

	go func() { log.Fatal(http.ListenAndServe(":8091", catalog)) }()
	log.Println("fixture: catalog on :8091, payments on :8092")
	log.Fatal(http.ListenAndServe(":8092", payments))
}

func ok(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
