package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPriceSubtotal(t *testing.T) {
	q := priceSubtotal(10000, "GA")
	if q.TaxCents != 700 || q.TotalCents != 10700 {
		t.Fatalf("got tax %d total %d, want 700 and 10700", q.TaxCents, q.TotalCents)
	}
}

func TestCheckoutPaid(t *testing.T) {
	catalog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(product{SKU: "SKU-1", Name: "Test item", PriceCents: 5000, InStock: true})
	}))
	defer catalog.Close()
	payments := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"id":"ch_test","status":"succeeded"}`))
	}))
	defer payments.Close()
	catalogURL, paymentsURL = catalog.URL, payments.URL

	req := httptest.NewRequest(http.MethodPost, "/api/checkout", strings.NewReader(`{"region":"GA","card_token":"tok_visa","items":[{"sku":"SKU-1","qty":2}]}`))
	rec := httptest.NewRecorder()
	newMux().ServeHTTP(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d, want 201", rec.Code)
	}
	var body map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if body["status"] != "paid" || body["total"] != "107.00" {
		t.Fatalf("got status %v total %v, want paid and 107.00", body["status"], body["total"])
	}
}
