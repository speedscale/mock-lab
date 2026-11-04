package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
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

func TestOuterspaceConcurrentResponses(t *testing.T) {
	mux := http.NewServeMux()
	if err := registerOuterspace(mux); err != nil {
		t.Fatal(err)
	}
	const path = "/outerspace/spacex/launches/latest"
	first := httptest.NewRecorder()
	mux.ServeHTTP(first, httptest.NewRequest("GET", path, nil))
	expected := append([]byte(nil), first.Body.Bytes()...)
	start := make(chan struct{})
	var workers sync.WaitGroup
	for i := 0; i < 32; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			for j := 0; j < 20; j++ {
				res := httptest.NewRecorder()
				mux.ServeHTTP(res, httptest.NewRequest("GET", path, nil))
				if res.Code != http.StatusOK || !bytes.Equal(res.Body.Bytes(), expected) {
					t.Error("concurrent response differs from the endpoint contract")
					return
				}
			}
		}()
	}
	close(start)
	workers.Wait()
}
