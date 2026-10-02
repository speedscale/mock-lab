package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"errors"
)

func TestCatalogRecoveryDefect(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(503)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte("[]"))
	}))
	defer server.Close()
	broken := NewUpstream(server.URL)
	broken.LatchFailures = true
	_, err := broken.Catalog(t.Context())
	if !errors.Is(err, errCatalogUnavailable) {
		t.Fatalf("expected catalog failure, got %v", err)
	}
	_, err = broken.Catalog(t.Context())
	if !errors.Is(err, errCatalogUnavailable) {
		t.Fatalf("expected catalog failure, got %v", err)
	}
	healthy := NewUpstream(server.URL)
	_, err = healthy.Catalog(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 {
		t.Fatalf("expected two upstream calls, got %d", calls.Load())
	}
}
