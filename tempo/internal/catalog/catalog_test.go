package catalog

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"go.opentelemetry.io/otel"
)

func TestBuildPreservesInputOrderAndAggregatesInventory(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/inventory/{productID}", func(w http.ResponseWriter, r *http.Request) {
		items := map[string]InventoryItem{
			"sku-a": {ProductID: "sku-a", Available: true, Quantity: 3},
			"sku-b": {ProductID: "sku-b", Available: false, Quantity: 0},
		}
		item, ok := items[r.PathValue("productID")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(item)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	service, err := NewService(server.Client(), server.URL, otel.Tracer("test"))
	if err != nil {
		t.Fatal(err)
	}

	got, err := service.Build(context.Background(), []string{"sku-b", "sku-a"})
	if err != nil {
		t.Fatal(err)
	}
	want := Result{
		Items: []InventoryItem{
			{ProductID: "sku-b", Available: false, Quantity: 0},
			{ProductID: "sku-a", Available: true, Quantity: 3},
		},
		RequestedItems: 2,
		AvailableItems: 1,
		TotalQuantity:  3,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Build() = %#v, want %#v", got, want)
	}
}

func TestBuildRejectsMismatchedProduct(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(InventoryItem{ProductID: "wrong", Available: true, Quantity: 10})
	}))
	defer server.Close()

	service, err := NewService(server.Client(), server.URL, otel.Tracer("test"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Build(context.Background(), []string{"sku-a"}); err == nil {
		t.Fatal("Build() error = nil, want product mismatch")
	}
}
