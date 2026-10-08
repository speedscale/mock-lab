// The pricing fixture: a deterministic dependency whose catalog contains one
// SKU inside a repricing window. That rare response shape is what drives the
// checkout API down its retry path.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

type catalogEntry struct {
	settledPriceCents int64
	repricing         bool
}

// SSC-7300 is the only SKU in a repricing window. Every other SKU settles
// immediately, which is why ordinary happy-path traffic never exercises the
// repricing branch of the checkout client.
var catalog = map[string]catalogEntry{
	"SSC-4110": {settledPriceCents: 1899},
	"SSC-4111": {settledPriceCents: 2499},
	"SSC-5200": {settledPriceCents: 649},
	"SSC-5201": {settledPriceCents: 4250},
	"SSC-6100": {settledPriceCents: 8125},
	"SSC-6101": {settledPriceCents: 3400},
	"SSC-7300": {settledPriceCents: 12999, repricing: true},
	"SSC-8200": {settledPriceCents: 999},
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	delay := 10 * time.Millisecond
	if value := os.Getenv("PRICING_DELAY_MS"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			log.Fatalf("PRICING_DELAY_MS must be a non-negative integer, got %q", value)
		}
		delay = time.Duration(parsed) * time.Millisecond
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /v1/price/{sku}", func(w http.ResponseWriter, r *http.Request) {
		sku := r.PathValue("sku")
		entry, known := catalog[sku]
		if !known {
			http.Error(w, "unknown sku", http.StatusNotFound)
			return
		}
		time.Sleep(delay)

		body := map[string]any{
			"sku":                      sku,
			"currency":                 "USD",
			"state":                    "SETTLED",
			"unit_price_cents":         entry.settledPriceCents,
			"last_settled_price_cents": entry.settledPriceCents,
		}
		if entry.repricing {
			// A repricing quote is a valid 200. The dependency withholds the
			// live price and republishes the last settled one, which is the
			// value callers are expected to honor for the duration.
			body["state"] = "REPRICING"
			body["unit_price_cents"] = 0
			body["repricing_window_ms"] = 900000
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(body); err != nil {
			return
		}
	})

	server := &http.Server{
		Addr:              envOrDefault("PRICING_ADDR", ":8090"),
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown server: %v", err)
		}
	}()

	log.Printf("pricing fixture listening on %s with %s lookup delay", server.Addr, delay)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
