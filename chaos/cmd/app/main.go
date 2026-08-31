// Command app is the storefront API the lab exercises. It answers
// GET /api/stock/{sku} by asking the inventory service how many units are on
// hand, and it has a fallback for when inventory is unavailable.
//
// The fallback is the point of the lab. It is written the way this is usually
// written, it looks finished, and it has never run: nothing in the test suite
// makes inventory fail, and inventory does not fail on demand.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type stockLevel struct {
	SKU          string `json:"sku"`
	Available    int    `json:"available"`
	WarehouseID  string `json:"warehouse_id"`
	ReorderPoint int    `json:"reorder_point"`
}

// stockResponse is what the storefront returns to its own callers. Degraded
// says the number came from the cache rather than from inventory, so a caller
// can decide whether to trust it.
type stockResponse struct {
	SKU       string `json:"sku"`
	Available int    `json:"available"`
	InStock   bool   `json:"in_stock"`
	Degraded  bool   `json:"degraded"`
	Source    string `json:"source"`
}

// lastKnown is the fallback cache: the most recent good answer per SKU.
var lastKnown = map[string]stockLevel{}

func main() {
	addr := os.Getenv("APP_ADDR")
	if addr == "" {
		addr = "127.0.0.1:8080"
	}
	inventoryURL := os.Getenv("INVENTORY_URL")
	if inventoryURL == "" {
		inventoryURL = "http://localhost:8090"
	}

	client := &http.Client{
		Timeout: 5 * time.Second,
		// Go's default ProxyFromEnvironment deliberately refuses to proxy
		// loopback addresses, and every dependency in this lab is on
		// 127.0.0.1. Without this the outbound calls bypass proxymock
		// entirely: the recording captures only inbound traffic, and the
		// chaos rules later have nothing to perturb.
		Transport: &http.Transport{Proxy: proxyFromEnvironmentIncludingLocalhost},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/api/stock/", func(w http.ResponseWriter, r *http.Request) {
		sku := strings.TrimPrefix(r.URL.Path, "/api/stock/")

		level, err := fetchStock(client, inventoryURL, sku)
		if err != nil {
			// The fallback: serve the last good answer and say so.
			cached, ok := lastKnown[sku]
			if !ok {
				log.Printf(`{"level":"error","sku":%q,"msg":"inventory unavailable and no cached level","err":%q}`, sku, err)
				http.Error(w, `{"error":"inventory unavailable"}`, http.StatusServiceUnavailable)
				return
			}
			log.Printf(`{"level":"warn","sku":%q,"msg":"inventory unavailable, serving cached level","err":%q}`, sku, err)
			writeJSON(w, stockResponse{
				SKU:       sku,
				Available: cached.Available,
				InStock:   cached.Available > 0,
				Degraded:  true,
				Source:    "cache",
			})
			return
		}

		lastKnown[sku] = level
		writeJSON(w, stockResponse{
			SKU:       level.SKU,
			Available: level.Available,
			InStock:   level.Available > 0,
			Degraded:  false,
			Source:    "inventory",
		})
	})

	log.Printf("storefront listening on %s, inventory at %s", addr, inventoryURL)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

// fetchStock asks inventory for one SKU.
func fetchStock(client *http.Client, base, sku string) (stockLevel, error) {
	var level stockLevel

	resp, err := client.Get(fmt.Sprintf("%s/v1/inventory/%s", base, sku))
	if err != nil {
		return level, fmt.Errorf("calling inventory: %w", err)
	}
	defer resp.Body.Close()

	if err := json.NewDecoder(resp.Body).Decode(&level); err != nil {
		return level, fmt.Errorf("decoding inventory response: %w", err)
	}
	return level, nil
}

// proxyFromEnvironmentIncludingLocalhost mirrors http.ProxyFromEnvironment
// but keeps proxying loopback destinations, which the standard helper skips.
func proxyFromEnvironmentIncludingLocalhost(r *http.Request) (*url.URL, error) {
	for _, key := range []string{
		strings.ToUpper(r.URL.Scheme) + "_PROXY",
		strings.ToLower(r.URL.Scheme) + "_proxy",
		"ALL_PROXY",
		"all_proxy",
	} {
		if v := os.Getenv(key); v != "" {
			return url.Parse(v)
		}
	}
	return nil, nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
