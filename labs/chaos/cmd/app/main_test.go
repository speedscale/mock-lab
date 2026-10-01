package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestFetchStockCoverage exercises transport and decode paths, not non-2xx status handling.
func TestFetchStockCoverage(t *testing.T) {
	const stockJSON = `{"sku":"SSC-4110","available":42,"warehouse_id":"west","reorder_point":8}`

	tests := []struct {
		name       string
		statusCode int
		body       string
		wantErr    bool
	}{
		{name: "healthy response", statusCode: http.StatusOK, body: stockJSON},
		{name: "invalid body", statusCode: http.StatusOK, body: "not json", wantErr: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(test.statusCode)
				_, _ = w.Write([]byte(test.body))
			}))
			defer server.Close()

			got, err := fetchStock(server.Client(), server.URL, "SSC-4110")
			if (err != nil) != test.wantErr {
				t.Fatalf("fetchStock() error = %v, wantErr %v", err, test.wantErr)
			}
			if !test.wantErr && got.Available != 42 {
				t.Fatalf("fetchStock() available = %d, want 42", got.Available)
			}
		})
	}

	t.Run("transport error", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
		base := server.URL
		server.Close()

		_, err := fetchStock(http.DefaultClient, base, "SSC-4110")
		if err == nil || !strings.Contains(err.Error(), "calling inventory") {
			t.Fatalf("fetchStock() error = %v, want calling inventory error", err)
		}
	})
}

func TestStockHandler(t *testing.T) {
	const stockJSON = `{"sku":"SSC-4110","available":42,"warehouse_id":"west","reorder_point":8}`

	t.Run("healthy response", func(t *testing.T) {
		inventory := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(stockJSON))
		}))
		defer inventory.Close()

		response := requestStock(newHandler(inventory.Client(), inventory.URL), "SSC-4110")
		var got stockResponse
		if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if response.Code != http.StatusOK || got.Source != "inventory" || got.Degraded {
			t.Fatalf("healthy response = %d %+v", response.Code, got)
		}
	})

	t.Run("cached response after transport failure", func(t *testing.T) {
		inventory := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(stockJSON))
		}))
		handler := newHandler(inventory.Client(), inventory.URL)
		if response := requestStock(handler, "SSC-4110"); response.Code != http.StatusOK {
			t.Fatalf("baseline response = %d", response.Code)
		}
		base := inventory.URL
		inventory.Close()

		response := requestStock(newHandler(http.DefaultClient, base), "SSC-4110")
		if response.Code != http.StatusServiceUnavailable {
			t.Fatalf("empty-cache response = %d, want %d", response.Code, http.StatusServiceUnavailable)
		}
		response = requestStock(handler, "SSC-4110")
		var got stockResponse
		if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
			t.Fatal(err)
		}
		if response.Code != http.StatusOK || got.Source != "cache" || !got.Degraded {
			t.Fatalf("cached response = %d %+v", response.Code, got)
		}
	})

	t.Run("unavailable without cache", func(t *testing.T) {
		inventory := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.WriteHeader(http.StatusOK)
			_, _ = fmt.Fprint(w, "not json")
		}))
		defer inventory.Close()

		response := requestStock(newHandler(inventory.Client(), inventory.URL), "SSC-4110")
		if response.Code != http.StatusServiceUnavailable {
			t.Fatalf("response = %d, want %d", response.Code, http.StatusServiceUnavailable)
		}
	})

	t.Run("health", func(t *testing.T) {
		response := httptest.NewRecorder()
		newHandler(http.DefaultClient, "").ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/healthz", nil))
		if response.Code != http.StatusOK {
			t.Fatalf("health response = %d, want %d", response.Code, http.StatusOK)
		}
	})
}

func TestProxyFromEnvironmentIncludingLocalhost(t *testing.T) {
	for _, key := range []string{"HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"} {
		t.Setenv(key, "")
	}
	t.Setenv("ALL_PROXY", "http://127.0.0.1:4140")
	request := httptest.NewRequest(http.MethodGet, "http://localhost:8090/v1/inventory/SSC-4110", nil)
	got, err := proxyFromEnvironmentIncludingLocalhost(request)
	if err != nil || got == nil || got.String() != "http://127.0.0.1:4140" {
		t.Fatalf("proxy = %v, error = %v", got, err)
	}

	t.Setenv("ALL_PROXY", "")
	got, err = proxyFromEnvironmentIncludingLocalhost(request)
	if err != nil || got != nil {
		t.Fatalf("proxy = %v, error = %v, want no proxy", got, err)
	}
}

func requestStock(handler http.Handler, sku string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/stock/"+sku, nil)
	handler.ServeHTTP(response, request)
	return response
}
