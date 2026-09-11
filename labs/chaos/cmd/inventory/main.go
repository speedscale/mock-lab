// Command inventory is the downstream dependency the storefront calls. It is
// only needed once, to record a session; every later step in the lab serves it
// from the recording instead.
//
// It is deliberately boring and always healthy. The lab's whole point is that
// you do not need a dependency that misbehaves in order to test what happens
// when it does.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
)

type stockLevel struct {
	SKU          string `json:"sku"`
	Available    int    `json:"available"`
	WarehouseID  string `json:"warehouse_id"`
	ReorderPoint int    `json:"reorder_point"`
}

var catalog = map[string]stockLevel{
	"SSC-4110": {SKU: "SSC-4110", Available: 42, WarehouseID: "ATL-1", ReorderPoint: 10},
	"SSC-4111": {SKU: "SSC-4111", Available: 7, WarehouseID: "ATL-1", ReorderPoint: 10},
	"SSC-5200": {SKU: "SSC-5200", Available: 118, WarehouseID: "PDX-2", ReorderPoint: 25},
	"SSC-5201": {SKU: "SSC-5201", Available: 0, WarehouseID: "PDX-2", ReorderPoint: 25},
	"SSC-6100": {SKU: "SSC-6100", Available: 63, WarehouseID: "ATL-1", ReorderPoint: 15},
	"SSC-7300": {SKU: "SSC-7300", Available: 9, WarehouseID: "DFW-3", ReorderPoint: 20},
}

func main() {
	addr := os.Getenv("INVENTORY_ADDR")
	if addr == "" {
		addr = "localhost:8090"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/v1/inventory/", func(w http.ResponseWriter, r *http.Request) {
		sku := strings.TrimPrefix(r.URL.Path, "/v1/inventory/")
		level, ok := catalog[sku]
		if !ok {
			http.Error(w, `{"error":"unknown sku"}`, http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(level)
	})

	log.Printf("inventory listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
