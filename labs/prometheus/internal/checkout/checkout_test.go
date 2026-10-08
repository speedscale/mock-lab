package checkout

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
)

func newTestService(t *testing.T, pricing http.HandlerFunc) *Service {
	t.Helper()
	backend := httptest.NewServer(pricing)
	t.Cleanup(backend.Close)
	return NewService(backend.URL, NewMetrics(prometheus.NewRegistry()))
}

func pricingStub(t *testing.T, sku string, unitPrice int64) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/price/"+sku {
			t.Errorf("unexpected pricing path %q", r.URL.Path)
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sku":              sku,
			"unit_price_cents": unitPrice,
			"currency":         "USD",
		})
	}
}

func TestQuoteMultipliesUnitPrice(t *testing.T) {
	service := newTestService(t, pricingStub(t, "SSC-4110", 1899))

	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-4110&qty=3", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body: %s", recorder.Code, recorder.Body.String())
	}
	var quote quoteResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &quote); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	want := quoteResponse{SKU: "SSC-4110", Quantity: 3, UnitPriceCents: 1899, TotalCents: 5697, Currency: "USD"}
	if quote != want {
		t.Fatalf("quote = %+v, want %+v", quote, want)
	}
}

func TestRejectsInvalidInput(t *testing.T) {
	service := newTestService(t, func(w http.ResponseWriter, _ *http.Request) {
		t.Error("pricing must not be called for invalid input")
		http.Error(w, "unexpected", http.StatusInternalServerError)
	})

	for _, target := range []string{
		"/api/quote?sku=lowercase-1&qty=1",
		"/api/quote?sku=SSC-4110&qty=0",
		"/api/quote?sku=SSC-4110&qty=100",
		"/api/quote?sku=SSC-4110&qty=three",
		"/api/quote?qty=1",
	} {
		recorder := httptest.NewRecorder()
		service.Handler()(recorder, httptest.NewRequest(http.MethodGet, target, nil))
		if recorder.Code != http.StatusBadRequest {
			t.Errorf("%s: status = %d, want 400", target, recorder.Code)
		}
	}
}

func TestDependencyFailureMapsToBadGateway(t *testing.T) {
	service := newTestService(t, func(w http.ResponseWriter, _ *http.Request) {
		http.Error(w, "pricing exploded", http.StatusInternalServerError)
	})

	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-4110&qty=2", nil))
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", recorder.Code)
	}
}

func TestRejectsMismatchedPricingResponse(t *testing.T) {
	service := newTestService(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sku":              "SSC-9999",
			"unit_price_cents": 100,
			"currency":         "USD",
		})
	})

	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-4110&qty=2", nil))
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", recorder.Code)
	}
}
