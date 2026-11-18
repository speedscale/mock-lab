package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestServiceTokenNamesTheShopperBySubOnly(t *testing.T) {
	parts := strings.Split(serviceToken("u-alice-1001"), ".")
	if len(parts) != 3 {
		t.Fatalf("want a three-part JWT, got %d parts", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(payload, &claims); err != nil {
		t.Fatal(err)
	}
	if claims["sub"] != "u-alice-1001" {
		t.Errorf("sub = %v, want u-alice-1001", claims["sub"])
	}
	if _, has := claims["uid"]; has {
		t.Error("the service token must not carry uid, or it would share the shopper's session ID")
	}
}

func TestUIDFromBearer(t *testing.T) {
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	token := enc(map[string]string{"alg": "none"}) + "." + enc(map[string]string{"uid": "u-bob-2002"}) + ".sig"
	for _, tc := range []struct {
		header string
		want   string
		ok     bool
	}{
		{"Bearer " + token, "u-bob-2002", true},
		{"Basic dXNlcjpwYXNz", "", false},
		{"Bearer not-a-jwt", "", false},
	} {
		got, ok := uidFromBearer(tc.header)
		if got != tc.want || ok != tc.ok {
			t.Errorf("uidFromBearer(%q) = %q, %v; want %q, %v", tc.header, got, ok, tc.want, tc.ok)
		}
	}
}
