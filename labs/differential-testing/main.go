package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"
)

var (
	catalogURL  = envOr("CATALOG_URL", "http://localhost:8091")
	paymentsURL = envOr("PAYMENTS_URL", "http://localhost:8092")
	client      = &http.Client{Timeout: 5 * time.Second}
)

// Tax rates in parts per million, so 8.25% is 82500.
var taxPPM = map[string]int64{
	"CA": 82500,
	"GA": 70000,
	"NJ": 66250,
	"OR": 0,
	"TX": 62500,
}

type item struct {
	SKU string `json:"sku"`
	Qty int64  `json:"qty"`
}

type cart struct {
	Items     []item `json:"items"`
	Region    string `json:"region"`
	CardToken string `json:"card_token,omitempty"`
}

type product struct {
	SKU        string `json:"sku"`
	Name       string `json:"name"`
	PriceCents int64  `json:"price_cents"`
	InStock    bool   `json:"in_stock"`
}

type quote struct {
	SubtotalCents int64
	TaxCents      int64
	TotalCents    int64
}

type chargeResult struct {
	Status        int
	ChargeID      string
	DeclineReason string
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Honor the proxy for loopback dependencies as well.
func proxyFromEnvAnyHost(req *http.Request) (*url.URL, error) {
	keys := []string{"HTTP_PROXY", "http_proxy"}
	if req.URL.Scheme == "https" {
		keys = []string{"HTTPS_PROXY", "https_proxy"}
	}
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			return url.Parse(v)
		}
	}
	return nil, nil
}

func main() {
	client.Transport = &http.Transport{Proxy: proxyFromEnvAnyHost, MaxIdleConnsPerHost: 64}
	port := envOr("PORT", "8080")
	log.Printf("checkout listening on :%s (catalog=%s payments=%s)", port, catalogURL, paymentsURL)
	log.Fatal(http.ListenAndServe(":"+port, newMux()))
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("GET /api/products/{sku}", productHandler)
	mux.HandleFunc("POST /api/quote", quoteHandler)
	mux.HandleFunc("POST /api/checkout", checkoutHandler)
	return mux
}

func productHandler(w http.ResponseWriter, r *http.Request) {
	p, status, err := fetchProduct(r.PathValue("sku"))
	if err != nil {
		writeJSON(w, status, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"sku":      p.SKU,
		"name":     p.Name,
		"price":    money(p.PriceCents),
		"in_stock": p.InStock,
	})
}

func quoteHandler(w http.ResponseWriter, r *http.Request) {
	c, ok := readCart(w, r)
	if !ok {
		return
	}
	q, status, err := priceCart(c)
	if err != nil {
		writeJSON(w, status, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, quoteBody(q))
}

func checkoutHandler(w http.ResponseWriter, r *http.Request) {
	c, ok := readCart(w, r)
	if !ok {
		return
	}
	if c.CardToken == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "card_token is required"})
		return
	}
	q, status, err := priceCart(c)
	if err != nil {
		writeJSON(w, status, map[string]any{"error": err.Error()})
		return
	}
	res := charge(q.TotalCents, c.CardToken)
	switch {
	case res.Status == http.StatusCreated:
		body := quoteBody(q)
		body["status"] = "paid"
		body["order_id"] = newOrderID()
		body["charge_id"] = res.ChargeID
		body["created"] = time.Now().UTC().Format(time.RFC3339)
		writeJSON(w, http.StatusCreated, body)
	case res.Status == http.StatusPaymentRequired:
		writeJSON(w, http.StatusPaymentRequired, map[string]any{"status": "declined", "reason": res.DeclineReason})
	default:
		// The processor is down or unreachable. The card was never judged.
		w.Header().Set("Retry-After", "30")
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "payment_unavailable", "retryable": true})
	}
}

func readCart(w http.ResponseWriter, r *http.Request) (cart, bool) {
	var c cart
	if err := json.NewDecoder(r.Body).Decode(&c); err != nil || len(c.Items) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "cart needs at least one item"})
		return c, false
	}
	if _, known := taxPPM[c.Region]; !known {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "unsupported region"})
		return c, false
	}
	return c, true
}

func priceCart(c cart) (quote, int, error) {
	var subtotal int64
	for _, it := range c.Items {
		p, status, err := fetchProduct(it.SKU)
		if err != nil {
			return quote{}, status, err
		}
		subtotal += p.PriceCents * it.Qty
	}
	return priceSubtotal(subtotal, c.Region), http.StatusOK, nil
}

// priceSubtotal works in integer cents and rounds tax half up.
func priceSubtotal(subtotalCents int64, region string) quote {
	tax := (subtotalCents*taxPPM[region] + 500000) / 1000000
	return quote{SubtotalCents: subtotalCents, TaxCents: tax, TotalCents: subtotalCents + tax}
}

func quoteBody(q quote) map[string]any {
	return map[string]any{
		"subtotal": money(q.SubtotalCents),
		"tax":      money(q.TaxCents),
		"total":    money(q.TotalCents),
		"currency": "USD",
	}
}

func fetchProduct(sku string) (product, int, error) {
	resp, err := client.Get(catalogURL + "/v1/skus/" + url.PathEscape(sku))
	if err != nil {
		return product{}, http.StatusBadGateway, fmt.Errorf("catalog unreachable")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return product{}, http.StatusNotFound, fmt.Errorf("unknown sku %s", sku)
	}
	if resp.StatusCode != http.StatusOK {
		return product{}, http.StatusBadGateway, fmt.Errorf("catalog returned %d", resp.StatusCode)
	}
	var p product
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		return product{}, http.StatusBadGateway, fmt.Errorf("catalog response unreadable")
	}
	return p, http.StatusOK, nil
}

// charge reports the processor's status so the caller can tell a declined
// card from a processor that did not answer.
func charge(amountCents int64, cardToken string) chargeResult {
	payload, _ := json.Marshal(map[string]any{
		"amount_cents": amountCents,
		"currency":     "USD",
		"card_token":   cardToken,
	})
	resp, err := client.Post(paymentsURL+"/v1/charges", "application/json", bytes.NewReader(payload))
	if err != nil {
		return chargeResult{Status: http.StatusServiceUnavailable}
	}
	defer resp.Body.Close()
	var body struct {
		ID    string `json:"id"`
		Error struct {
			DeclineCode string `json:"decline_code"`
		} `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	return chargeResult{Status: resp.StatusCode, ChargeID: body.ID, DeclineReason: body.Error.DeclineCode}
}

func money(cents int64) string {
	return fmt.Sprintf("%d.%02d", cents/100, cents%100)
}

func newOrderID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(body)
}
