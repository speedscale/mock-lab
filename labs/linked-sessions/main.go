// The storefront is a small service whose users change session ID on the way
// through it. A shopper signs in with a JWT that carries their user ID, the
// storefront calls the payment service with a token of its own that names the
// shopper only by its sub claim, and the shopper's browser comes back later
// with nothing but a jsessionid and the payment ID it was given.
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

var (
	paymentsURL = envOr("PAYMENTS_URL", "http://localhost:8091")
	ordersURL   = envOr("ORDERS_URL", "http://localhost:8092")
	client      = &http.Client{Timeout: 5 * time.Second}
	// signingKey signs the storefront's own service tokens. It is a lab value.
	signingKey = []byte(envOr("SERVICE_TOKEN_KEY", "mock-lab-linked-sessions"))
)

const tenantID = "tenant-acme-001"

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// Honor the proxy for loopback dependencies as well, so proxymock records them.
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
	client.Transport = &http.Transport{Proxy: proxyFromEnvAnyHost, MaxIdleConnsPerHost: 16}
	port := envOr("PORT", "8080")
	log.Printf("storefront listening on :%s (payments=%s orders=%s)", port, paymentsURL, ordersURL)
	log.Fatal(http.ListenAndServe(":"+port, newMux()))
}

func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /api/config", configHandler)
	mux.HandleFunc("POST /api/checkout", checkoutHandler)
	mux.HandleFunc("GET /api/payments/{id}", paymentStatusHandler)
	mux.HandleFunc("GET /api/receipts/{id}", receiptHandler)
	mux.HandleFunc("POST /api/payments/lookup", lookupHandler)
	mux.HandleFunc("GET /api/orders", ordersHandler)
	mux.HandleFunc("GET /api/profile", profileHandler)
	return mux
}

// configHandler hands every client the tenant ID they send back on each call.
func configHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"tenantId": tenantID, "currency": "USD"})
}

// checkoutHandler charges the signed-in shopper. The call to the payment
// service carries the storefront's own token, which names the shopper by sub.
func checkoutHandler(w http.ResponseWriter, r *http.Request) {
	uid, ok := uidFromBearer(r.Header.Get("Authorization"))
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "sign in first"})
		return
	}
	var cart struct {
		AmountCents int64 `json:"amount_cents"`
	}
	if err := json.NewDecoder(r.Body).Decode(&cart); err != nil || cart.AmountCents <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "amount_cents is required"})
		return
	}
	body, _ := json.Marshal(map[string]int64{"amount_cents": cart.AmountCents})
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodPost, paymentsURL+"/v1/payments", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+serviceToken(uid))
	forward(r, req)
	var p struct {
		ID     string `json:"paymentId"`
		Status string `json:"status"`
	}
	if status, err := call(req, &p); err != nil || status != http.StatusCreated {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "payment failed"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"paymentId": p.ID, "status": p.Status})
}

// paymentStatusHandler serves the shopper's browser, which knows only its
// jsessionid and the payment ID from checkout.
func paymentStatusHandler(w http.ResponseWriter, r *http.Request) {
	p, status := fetchPayment(r, r.PathValue("id"))
	writeJSON(w, status, p)
}

// receiptHandler serves a receipt link from an email: no session, no credential.
func receiptHandler(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	p, status := fetchPayment(r, id)
	if status != http.StatusOK {
		writeJSON(w, status, p)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"receipt": id, "amount_cents": p["amount_cents"]})
}

// lookupHandler serves a support tool that checks several payments at once.
func lookupHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IDs []string `json:"ids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "ids is required"})
		return
	}
	out := make([]map[string]any, 0, len(req.IDs))
	for _, id := range req.IDs {
		p, _ := fetchPayment(r, id)
		out = append(out, p)
	}
	writeJSON(w, http.StatusOK, map[string]any{"payments": out})
}

// ordersHandler serves a browser session. The order service is called with a
// partner token, and the browser's trace context is passed along.
func ordersHandler(w http.ResponseWriter, r *http.Request) {
	session := r.URL.Query().Get("jsessionid")
	if session == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "no session"})
		return
	}
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, ordersURL+"/v1/orders", nil)
	req.Header.Set("Authorization", "Bearer "+partnerToken(session))
	forward(r, req)
	var out any
	status, err := call(req, &out)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "orders unavailable"})
		return
	}
	writeJSON(w, status, out)
}

// profileHandler serves an internal tool that signs in with Basic auth.
func profileHandler(w http.ResponseWriter, r *http.Request) {
	user, _, ok := r.BasicAuth()
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "sign in first"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"user": user})
}

func fetchPayment(r *http.Request, id string) (map[string]any, int) {
	req, _ := http.NewRequestWithContext(r.Context(), http.MethodGet, paymentsURL+"/v1/payments/"+url.PathEscape(id), nil)
	forward(r, req)
	var p map[string]any
	status, err := call(req, &p)
	if err != nil {
		return map[string]any{"error": "payments unavailable"}, http.StatusBadGateway
	}
	return p, status
}

// forward passes the tenant and the caller's trace context to a dependency.
func forward(in, out *http.Request) {
	for _, h := range []string{"X-Tenant-Id", "traceparent"} {
		if v := in.Header.Get(h); v != "" {
			out.Header.Set(h, v)
		}
	}
}

func call(req *http.Request, into any) (int, error) {
	resp, err := client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return 0, err
	}
	if len(b) > 0 {
		if err := json.Unmarshal(b, into); err != nil {
			return 0, err
		}
	}
	return resp.StatusCode, nil
}

// uidFromBearer reads the uid claim of the shopper's token. The identity
// provider signed it; this lab trusts it without checking the signature.
func uidFromBearer(header string) (string, bool) {
	token, found := strings.CutPrefix(header, "Bearer ")
	if !found {
		return "", false
	}
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", false
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", false
	}
	var claims struct {
		UID string `json:"uid"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.UID == "" {
		return "", false
	}
	return claims.UID, true
}

// serviceToken is the storefront's own JWT for the payment service. It names
// the shopper by sub and carries no uid, so it is a different session ID.
func serviceToken(uid string) string {
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	unsigned := enc(map[string]string{"alg": "HS256", "typ": "JWT"}) + "." +
		enc(map[string]any{"iss": "storefront", "sub": uid, "scope": "payments"})
	mac := hmac.New(sha256.New, signingKey)
	mac.Write([]byte(unsigned))
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// partnerToken is the opaque token the order service issued for a browser session.
func partnerToken(session string) string {
	sum := sha256.Sum256([]byte("partner:" + session))
	return fmt.Sprintf("ptk-%s", hex.EncodeToString(sum[:6]))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
