package checkout

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestService(t *testing.T, handler http.HandlerFunc) *Service {
	t.Helper()
	pricing := httptest.NewServer(handler)
	t.Cleanup(pricing.Close)
	return NewService(pricing.URL, slog.New(slog.NewJSONHandler(io.Discard, nil)))
}

func settledHandler(w http.ResponseWriter, _ *http.Request) {
	_ = json.NewEncoder(w).Encode(map[string]any{
		"sku":                      "SSC-4110",
		"currency":                 "USD",
		"state":                    "SETTLED",
		"unit_price_cents":         1899,
		"last_settled_price_cents": 1899,
	})
}

func repricingHandler(calls *int) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		*calls++
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sku":                      "SSC-7300",
			"currency":                 "USD",
			"state":                    "REPRICING",
			"unit_price_cents":         0,
			"last_settled_price_cents": 12999,
			"repricing_window_ms":      900000,
		})
	}
}

func decodeQuote(t *testing.T, recorder *httptest.ResponseRecorder) quoteResponse {
	t.Helper()
	var quote quoteResponse
	if err := json.NewDecoder(recorder.Body).Decode(&quote); err != nil {
		t.Fatalf("decode quote: %v", err)
	}
	return quote
}

func TestSettledPriceIsUsedDirectly(t *testing.T) {
	service := newTestService(t, settledHandler)
	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-4110&qty=3", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	quote := decodeQuote(t, recorder)
	if quote.UnitPriceCents != 1899 || quote.TotalCents != 5697 || quote.Currency != "USD" {
		t.Fatalf("unexpected quote %+v", quote)
	}
}

// A repricing answer must resolve to the dependency's last settled price. The
// response contract is identical no matter how the client gets there, which is
// what makes the retry path invisible from the outside.
func TestRepricingResolvesToLastSettledPrice(t *testing.T) {
	calls := 0
	service := newTestService(t, repricingHandler(&calls))
	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-7300&qty=2", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", recorder.Code)
	}
	quote := decodeQuote(t, recorder)
	if quote.UnitPriceCents != 12999 || quote.TotalCents != 25998 {
		t.Fatalf("unexpected quote %+v", quote)
	}
	if calls < 1 {
		t.Fatalf("pricing was never called")
	}
}

func TestInvalidInputIsRejected(t *testing.T) {
	service := newTestService(t, settledHandler)
	for _, target := range []string{
		"/api/quote?sku=nope&qty=1",
		"/api/quote?sku=SSC-4110&qty=0",
		"/api/quote?sku=SSC-4110&qty=100",
		"/api/quote?sku=SSC-4110",
	} {
		recorder := httptest.NewRecorder()
		service.Handler()(recorder, httptest.NewRequest(http.MethodGet, target, nil))
		if recorder.Code != http.StatusBadRequest {
			t.Fatalf("%s: status = %d, want 400", target, recorder.Code)
		}
	}
}

func TestUnknownDependencyStateIsAnError(t *testing.T) {
	service := newTestService(t, func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"sku":                      "SSC-4110",
			"currency":                 "USD",
			"state":                    "SOMETHING_NEW",
			"unit_price_cents":         1899,
			"last_settled_price_cents": 1899,
		})
	})
	recorder := httptest.NewRecorder()
	service.Handler()(recorder, httptest.NewRequest(http.MethodGet, "/api/quote?sku=SSC-4110&qty=1", nil))
	if recorder.Code != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502", recorder.Code)
	}
}
