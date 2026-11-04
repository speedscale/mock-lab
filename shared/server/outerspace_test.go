package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestOuterspaceHTTPMatchesStaticExport(t *testing.T) {
	mux := http.NewServeMux()
	if err := registerOuterspace(mux); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := exportOuterspace(dir); err != nil {
		t.Fatal(err)
	}
	paths := []string{
		"spacex/rockets.json", "spacex/rockets/5e9d0d95eda69973a809d1ec",
		"spacex/rockets/5e9d0d96eda699382d09d1ee", "spacex/launches/latest",
		"spacex/launches.json", "numbers/random/math", "nasa/planetary/apod",
	}
	for _, path := range paths {
		t.Run(path, func(t *testing.T) {
			res := httptest.NewRecorder()
			mux.ServeHTTP(res, httptest.NewRequest("GET", "/outerspace/"+path, nil))
			if res.Code != http.StatusOK || res.Header().Get("Content-Type") != "application/json" {
				t.Fatalf("HTTP %d: %s", res.Code, res.Body.String())
			}
			file, err := os.ReadFile(filepath.Join(dir, "outerspace", path))
			if err != nil {
				t.Fatal(err)
			}
			if !json.Valid(file) || !bytes.Equal(res.Body.Bytes(), file) {
				t.Fatal("HTTP/export mismatch")
			}
		})
	}
	res := httptest.NewRecorder()
	mux.ServeHTTP(res, httptest.NewRequest("GET", "/outerspace/spacex/rockets/missing", nil))
	if res.Code != http.StatusNotFound {
		t.Fatalf("unknown rocket: HTTP %d", res.Code)
	}
}
