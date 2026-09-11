// Package checkout implements the quote API that this lab observes with
// Prometheus. The service depends on a pricing lookup for every quote.
package checkout

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// The pricing service is fronted by a small connection budget so a burst of
// checkout traffic cannot open an unbounded number of sockets against it.
const pricingMaxConns = 2

var skuPattern = regexp.MustCompile(`^[A-Z]{2,4}-\d{3,5}$`)

const (
	maxQuantity      = 99
	pricingCallLimit = 5 * time.Second
)

type priceResponse struct {
	SKU            string `json:"sku"`
	UnitPriceCents int64  `json:"unit_price_cents"`
	Currency       string `json:"currency"`
}

type quoteResponse struct {
	SKU            string `json:"sku"`
	Quantity       int64  `json:"quantity"`
	UnitPriceCents int64  `json:"unit_price_cents"`
	TotalCents     int64  `json:"total_cents"`
	Currency       string `json:"currency"`
}

// Service resolves quotes by combining request input with the pricing
// dependency.
type Service struct {
	client     *http.Client
	pricingURL string
	metrics    *Metrics
}

// NewService wires the pricing HTTP client with its connection budget and the
// lab's metrics.
func NewService(pricingURL string, metrics *Metrics) *Service {
	transport := &http.Transport{
		Proxy:               proxyFromEnvironmentIncludingLocalhost,
		MaxIdleConns:        pricingMaxConns,
		MaxIdleConnsPerHost: pricingMaxConns,
		MaxConnsPerHost:     pricingMaxConns,
	}
	return &Service{
		client:     &http.Client{Timeout: pricingCallLimit, Transport: transport},
		pricingURL: strings.TrimRight(pricingURL, "/"),
		metrics:    metrics,
	}
}

// Handler serves GET /api/quote.
func (s *Service) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		sku := r.URL.Query().Get("sku")
		if !skuPattern.MatchString(sku) {
			http.Error(w, "sku must match "+skuPattern.String(), http.StatusBadRequest)
			return
		}
		quantity, err := strconv.ParseInt(r.URL.Query().Get("qty"), 10, 64)
		if err != nil || quantity < 1 || quantity > maxQuantity {
			http.Error(w, fmt.Sprintf("qty must be an integer from 1 to %d", maxQuantity), http.StatusBadRequest)
			return
		}

		price, err := s.fetchPrice(r.Context(), sku)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(quoteResponse{
			SKU:            price.SKU,
			Quantity:       quantity,
			UnitPriceCents: price.UnitPriceCents,
			TotalCents:     price.UnitPriceCents * quantity,
			Currency:       price.Currency,
		}); err != nil {
			return
		}
	}
}

func (s *Service) fetchPrice(ctx context.Context, sku string) (priceResponse, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, s.pricingURL+"/v1/price/"+url.PathEscape(sku), nil)
	if err != nil {
		return priceResponse{}, fmt.Errorf("build pricing request: %w", err)
	}

	var connWaitStart time.Time
	trace := &httptrace.ClientTrace{
		GetConn: func(string) { connWaitStart = time.Now() },
		GotConn: func(httptrace.GotConnInfo) {
			if !connWaitStart.IsZero() {
				s.metrics.ObserveConnWait(time.Since(connWaitStart))
			}
		},
	}
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), trace))

	response, err := s.client.Do(request)
	if err != nil {
		return priceResponse{}, fmt.Errorf("call pricing: %w", err)
	}
	defer func() {
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
	}()

	if response.StatusCode != http.StatusOK {
		return priceResponse{}, fmt.Errorf("pricing returned status %d", response.StatusCode)
	}

	var price priceResponse
	decoder := json.NewDecoder(io.LimitReader(response.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&price); err != nil {
		return priceResponse{}, fmt.Errorf("decode pricing response: %w", err)
	}
	if price.SKU != sku {
		return priceResponse{}, errors.New("pricing responded for a different sku")
	}
	if price.UnitPriceCents <= 0 || price.Currency == "" {
		return priceResponse{}, errors.New("pricing response is incomplete")
	}
	return price, nil
}

// net/http bypasses proxies for localhost. proxymock is a local proxy, so the
// lab reads the injected proxy variables directly for dependency calls.
func proxyFromEnvironmentIncludingLocalhost(request *http.Request) (*url.URL, error) {
	proxyAddress := firstNonEmpty(
		os.Getenv(strings.ToUpper(request.URL.Scheme)+"_PROXY"),
		os.Getenv(strings.ToLower(request.URL.Scheme)+"_proxy"),
		os.Getenv("ALL_PROXY"),
		os.Getenv("all_proxy"),
	)
	if proxyAddress == "" {
		return nil, nil
	}
	return url.Parse(proxyAddress)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
