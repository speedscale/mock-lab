// Package checkout implements the quote API that this lab observes with Loki.
// Every quote resolves a price through the pricing dependency, and the
// dependency occasionally answers with a repricing quote instead of a live
// price. How the client reacts to that answer is the subject of the lab.
package checkout

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	maxQuantity      = 99
	pricingCallLimit = 5 * time.Second

	// The pricing client makes one call and then retries an unsettled answer
	// three more times before giving up.
	pricingAttempts    = 4
	pricingBaseBackoff = 60 * time.Millisecond

	stateSettled   = "SETTLED"
	stateRepricing = "REPRICING"

	sourceLive         = "live"
	sourceLastSettled  = "last_settled"
	requestIDHeader    = "X-Request-Id"
	pricingConnBudget  = 16
	quoteRouteTemplate = "/api/quote"
)

var skuPattern = regexp.MustCompile(`^[A-Z]{2,4}-\d{3,5}$`)

type priceResponse struct {
	SKU                   string `json:"sku"`
	Currency              string `json:"currency"`
	State                 string `json:"state"`
	UnitPriceCents        int64  `json:"unit_price_cents"`
	LastSettledPriceCents int64  `json:"last_settled_price_cents"`
	RepricingWindowMS     int64  `json:"repricing_window_ms"`
}

type quoteResponse struct {
	SKU            string `json:"sku"`
	Quantity       int64  `json:"quantity"`
	UnitPriceCents int64  `json:"unit_price_cents"`
	TotalCents     int64  `json:"total_cents"`
	Currency       string `json:"currency"`
}

type resolvedPrice struct {
	unitPriceCents int64
	currency       string
	source         string
	attempts       int
}

// Service resolves quotes by combining request input with the pricing
// dependency.
type Service struct {
	client     *http.Client
	pricingURL string
	logger     *slog.Logger
}

// NewService wires the pricing HTTP client and the structured logger that
// ships this lab's evidence to Loki.
func NewService(pricingURL string, logger *slog.Logger) *Service {
	transport := &http.Transport{
		Proxy:               proxyFromEnvironmentIncludingLocalhost,
		MaxIdleConns:        pricingConnBudget,
		MaxIdleConnsPerHost: pricingConnBudget,
		MaxConnsPerHost:     pricingConnBudget,
	}
	return &Service{
		client:     &http.Client{Timeout: pricingCallLimit, Transport: transport},
		pricingURL: strings.TrimRight(pricingURL, "/"),
		logger:     logger,
	}
}

// Handler serves GET /api/quote.
func (s *Service) Handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		requestID := r.Header.Get(requestIDHeader)
		if requestID == "" {
			requestID = newRequestID()
		}
		logger := s.logger.With(
			"request_id", requestID,
			"route", quoteRouteTemplate,
		)

		sku := r.URL.Query().Get("sku")
		if !skuPattern.MatchString(sku) {
			logger.Warn("quote rejected by input validation",
				"event", "quote_rejected",
				"reason", "sku_format",
				"sku", sku,
				"status", http.StatusBadRequest,
			)
			http.Error(w, "sku must match "+skuPattern.String(), http.StatusBadRequest)
			return
		}
		quantity, err := strconv.ParseInt(r.URL.Query().Get("qty"), 10, 64)
		if err != nil || quantity < 1 || quantity > maxQuantity {
			logger.Warn("quote rejected by input validation",
				"event", "quote_rejected",
				"reason", "quantity_range",
				"sku", sku,
				"status", http.StatusBadRequest,
			)
			http.Error(w, fmt.Sprintf("qty must be an integer from 1 to %d", maxQuantity), http.StatusBadRequest)
			return
		}

		price, err := s.resolvePrice(r.Context(), logger, sku)
		if err != nil {
			logger.Error("quote failed at the pricing boundary",
				"event", "quote_failed",
				"sku", sku,
				"status", http.StatusBadGateway,
				"error", err.Error(),
				"duration_ms", time.Since(started).Milliseconds(),
			)
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(quoteResponse{
			SKU:            sku,
			Quantity:       quantity,
			UnitPriceCents: price.unitPriceCents,
			TotalCents:     price.unitPriceCents * quantity,
			Currency:       price.currency,
		}); err != nil {
			return
		}

		logger.Info("quote served",
			"event", "quote_served",
			"sku", sku,
			"quantity", quantity,
			"status", http.StatusOK,
			"price_source", price.source,
			"pricing_attempts", price.attempts,
			"duration_ms", time.Since(started).Milliseconds(),
		)
	}
}

// resolvePrice asks the pricing dependency for a price and retries while the
// answer is unsettled.
func (s *Service) resolvePrice(ctx context.Context, logger *slog.Logger, sku string) (resolvedPrice, error) {
	var latest priceResponse

	for attempt := 1; attempt <= pricingAttempts; attempt++ {
		price, err := s.fetchPrice(ctx, sku)
		if err != nil {
			return resolvedPrice{}, err
		}
		latest = price

		if price.State == stateSettled {
			return resolvedPrice{
				unitPriceCents: price.UnitPriceCents,
				currency:       price.Currency,
				source:         sourceLive,
				attempts:       attempt,
			}, nil
		}

		if attempt < pricingAttempts {
			backoff := pricingBaseBackoff << (attempt - 1)
			logger.Warn("pricing lookup is not settled, retrying",
				"event", "pricing_retry",
				"sku", sku,
				"dep_state", price.State,
				"attempt", attempt,
				"max_attempts", pricingAttempts,
				"backoff_ms", backoff.Milliseconds(),
			)
			select {
			case <-ctx.Done():
				return resolvedPrice{}, ctx.Err()
			case <-time.After(backoff):
			}
		}
	}

	if latest.LastSettledPriceCents <= 0 {
		return resolvedPrice{}, errors.New("pricing never settled and published no last settled price")
	}

	logger.Error("pricing retries exhausted, falling back to the last settled price",
		"event", "pricing_retry_exhausted",
		"sku", sku,
		"dep_state", latest.State,
		"attempts", pricingAttempts,
		"repricing_window_ms", latest.RepricingWindowMS,
		"fallback_price_cents", latest.LastSettledPriceCents,
		"price_source", sourceLastSettled,
	)
	return resolvedPrice{
		unitPriceCents: latest.LastSettledPriceCents,
		currency:       latest.Currency,
		source:         sourceLastSettled,
		attempts:       pricingAttempts,
	}, nil
}

func (s *Service) fetchPrice(ctx context.Context, sku string) (priceResponse, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, s.pricingURL+"/v1/price/"+url.PathEscape(sku), nil)
	if err != nil {
		return priceResponse{}, fmt.Errorf("build pricing request: %w", err)
	}

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
	if price.Currency == "" {
		return priceResponse{}, errors.New("pricing response is incomplete")
	}
	if price.State == stateSettled && price.UnitPriceCents <= 0 {
		return priceResponse{}, errors.New("settled pricing response carries no price")
	}
	if price.State != stateSettled && price.State != stateRepricing {
		return priceResponse{}, fmt.Errorf("pricing returned unknown state %q", price.State)
	}
	return price, nil
}

func newRequestID() string {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return "unknown"
	}
	return hex.EncodeToString(buffer)
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
