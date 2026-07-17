package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSignJWTRoundTrips verifies the hand-rolled HS256 JWT signs and verifies,
// and that its subject survives — the credential the "JWT · re-sign" readiness
// class keys on.
func TestSignJWTRoundTrips(t *testing.T) {
	tok := signJWT("alice")

	if n := len(strings.Split(tok, ".")); n != 3 {
		t.Fatalf("JWT should have 3 segments, got %d", n)
	}
	sub, ok := jwtSubject(tok)
	if !ok {
		t.Fatal("freshly signed JWT should verify")
	}
	if sub != "alice" {
		t.Fatalf("subject = %q, want alice", sub)
	}

	// Distinct subjects yield distinct tokens → distinct recorded sessions.
	if signJWT("alice") == "" || signJWT("bob") == signJWT("alice") {
		t.Fatal("different subjects must produce different tokens")
	}
}

// TestJWTRejectsTampered ensures a mutated payload fails signature verification,
// so the token is a real signed credential, not just an encoded blob.
func TestJWTRejectsTampered(t *testing.T) {
	tok := signJWT("alice")
	parts := strings.Split(tok, ".")
	// Swap the payload for one claiming a different subject, keep the signature.
	parts[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"attacker","exp":9999999999}`))
	if _, ok := jwtSubject(strings.Join(parts, ".")); ok {
		t.Fatal("tampered JWT must not verify")
	}

	if _, ok := jwtSubject("not-a-jwt"); ok {
		t.Fatal("malformed token must not verify")
	}
}

// TestBasicCredentialSet confirms the Basic-auth demo users are the fixed set the
// "Basic · cred set" readiness class and the Replace-credentials wizard expect.
func TestBasicCredentialSet(t *testing.T) {
	if demoBasicUsers["acme"] != "acme-secret" || demoBasicUsers["globex"] != "globex-secret" {
		t.Fatal("demo Basic credential set changed unexpectedly")
	}
}

// TestLoginProfileFlow drives the JWT flow end-to-end in-process: log in for a
// subject, then present the issued bearer to the JWT-protected endpoint.
func TestLoginProfileFlow(t *testing.T) {
	// POST /auth/login → JWT
	lw := httptest.NewRecorder()
	loginHandler(lw, httptest.NewRequest(http.MethodPost, "/auth/login", strings.NewReader(`{"username":"alice"}`)))
	if lw.Code != http.StatusOK {
		t.Fatalf("login status = %d, want 200", lw.Code)
	}
	var login struct {
		AccessToken string `json:"access_token"`
		TokenType   string `json:"token_type"`
	}
	if err := json.Unmarshal(lw.Body.Bytes(), &login); err != nil {
		t.Fatalf("login body: %v", err)
	}
	if login.TokenType != "Bearer" || login.AccessToken == "" {
		t.Fatalf("login response missing bearer: %+v", login)
	}

	// GET /api/profile with the bearer → 200 + subject.
	pr := httptest.NewRequest(http.MethodGet, "/api/profile", nil)
	pr.Header.Set("Authorization", "Bearer "+login.AccessToken)
	pw := httptest.NewRecorder()
	profileHandler(pw, pr)
	if pw.Code != http.StatusOK {
		t.Fatalf("profile status = %d, want 200 (body %s)", pw.Code, pw.Body.String())
	}
	if !strings.Contains(pw.Body.String(), `"alice"`) {
		t.Fatalf("profile should echo the subject, got %s", pw.Body.String())
	}

	// Missing/invalid bearer → 401.
	uw := httptest.NewRecorder()
	profileHandler(uw, httptest.NewRequest(http.MethodGet, "/api/profile", nil))
	if uw.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated profile = %d, want 401", uw.Code)
	}
}

// TestAccountBasicAuth exercises the Basic-auth endpoint: a valid credential set
// member passes, a wrong password fails.
func TestAccountBasicAuth(t *testing.T) {
	ok := httptest.NewRequest(http.MethodGet, "/api/account", nil)
	ok.SetBasicAuth("acme", "acme-secret")
	okw := httptest.NewRecorder()
	accountHandler(okw, ok)
	if okw.Code != http.StatusOK {
		t.Fatalf("valid basic auth = %d, want 200 (body %s)", okw.Code, okw.Body.String())
	}
	if !strings.Contains(okw.Body.String(), `"acme"`) {
		t.Fatalf("account should echo the user, got %s", okw.Body.String())
	}

	bad := httptest.NewRequest(http.MethodGet, "/api/account", nil)
	bad.SetBasicAuth("acme", "wrong")
	badw := httptest.NewRecorder()
	accountHandler(badw, bad)
	if badw.Code != http.StatusUnauthorized {
		t.Fatalf("bad basic auth = %d, want 401", badw.Code)
	}
}
