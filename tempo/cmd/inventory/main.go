package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/speedscale/mock-lab/tempo-demo/internal/catalog"
)

const responseDelay = 35 * time.Millisecond

func main() {
	address := envOrDefault("INVENTORY_ADDR", ":8090")
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /v1/inventory/{productID}", func(w http.ResponseWriter, r *http.Request) {
		productID := r.PathValue("productID")
		quantity, ok := quantityFor(productID)
		if !ok {
			http.Error(w, "unknown product", http.StatusNotFound)
			return
		}
		time.Sleep(responseDelay)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(catalog.InventoryItem{
			ProductID: productID,
			Available: quantity > 0,
			Quantity:  quantity,
		})
	})

	log.Printf("deterministic inventory listening on %s with %s response delay", address, responseDelay)
	log.Fatal(http.ListenAndServe(address, mux))
}

func quantityFor(productID string) (int, bool) {
	if !strings.HasPrefix(productID, "sku-") {
		return 0, false
	}
	number, err := strconv.Atoi(strings.TrimPrefix(productID, "sku-"))
	if err != nil || number < 1 || number > 999 {
		return 0, false
	}
	return (number * 7) % 23, true
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
