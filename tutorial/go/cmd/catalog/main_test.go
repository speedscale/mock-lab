package main

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestDeterministicCatalog(t *testing.T) {
	response := httptest.NewRecorder()
	routes().ServeHTTP(response, httptest.NewRequest("GET", "/v1/projects?ts=123", nil))
	var got []project
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if response.Code != 200 || len(got) != 3 || got[0].Maturity != "Graduated" {
		t.Fatalf("unexpected catalog: %s", response.Body.String())
	}
	response = httptest.NewRecorder()
	routes().ServeHTTP(response, httptest.NewRequest("GET", "/v1/project/unknown", nil))
	if response.Code != 404 {
		t.Fatalf("unknown project status=%d", response.Code)
	}
}
