// The pricing fixture: a deterministic dependency with a fixed lookup delay so
// connection queueing in the checkout API is reproducible.
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

var catalog = map[string]int64{
	"SSC-4110": 1899,
	"SSC-4111": 2499,
	"SSC-5200": 649,
	"SSC-5201": 4250,
	"SSC-7300": 12999,
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	delay := 40 * time.Millisecond
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
		unitPrice, known := catalog[sku]
		if !known {
			http.Error(w, "unknown sku", http.StatusNotFound)
			return
		}
		time.Sleep(delay)
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(map[string]any{
			"sku":              sku,
			"unit_price_cents": unitPrice,
			"currency":         "USD",
		}); err != nil {
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
