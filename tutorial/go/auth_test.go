package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestFixtureAuth(t *testing.T) {
	for _, tc := range []struct {
		name, path, token string
		want              int
	}{
		{"health is ready without credentials", "/healthz", "", 200},
		{"missing credential", "/orders", "", 401},
		{"wrong credential", "/orders", "Bearer wrong", 401},
		{"valid credential reaches router", "/absent", "Bearer test-only", 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			app := &App{AuthToken: "test-only"}
			req := httptest.NewRequest(http.MethodGet, tc.path, nil)
			req.Header.Set("Authorization", tc.token)
			response := httptest.NewRecorder()
			app.Routes().ServeHTTP(response, req)
			if response.Code != tc.want {
				t.Fatalf("status=%d, want=%d", response.Code, tc.want)
			}
		})
	}
}
