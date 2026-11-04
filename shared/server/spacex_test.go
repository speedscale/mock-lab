package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestSpaceXContract(t *testing.T) {
	dir := t.TempDir()
	if err := exportSpaceX(dir); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ path, id, name string }{
		{"/spacex/v5/launches/latest", "62dd70d5202306255024d139", "Crew-5"},
		{"/spacex/v4/ships/614251b711a64135defb3654", "614251b711a64135defb3654", "Doug"},
		{"/spacex/v4/ships/5ea6ed30080df4000697c916", "5ea6ed30080df4000697c916", "RACHEL"},
		{"/spacex/v4/ships/618fad7e563d69573ed8caa9", "618fad7e563d69573ed8caa9", "Bob"},
	}
	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			rr := httptest.NewRecorder()
			serveSpaceX(rr, httptest.NewRequest(http.MethodGet, tc.path, nil))
			if rr.Code != http.StatusOK || rr.Header().Get("Content-Type") != "application/json" {
				t.Fatalf("response: %d %s", rr.Code, rr.Body)
			}
			var body struct{ ID, Name string }
			if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.ID != tc.id || body.Name != tc.name {
				t.Fatalf("unexpected body: %s", rr.Body)
			}
			exported, err := os.ReadFile(filepath.Join(dir, tc.path[1:]))
			if err != nil {
				t.Fatal(err)
			}
			if string(exported) != rr.Body.String() {
				t.Fatal("static export differs from HTTP response")
			}
		})
	}
	for _, path := range []string{"/spacex/v4/ships/unknown", "/spacex/../data/projects"} {
		rr := httptest.NewRecorder()
		serveSpaceX(rr, httptest.NewRequest(http.MethodGet, path, nil))
		if rr.Code != http.StatusNotFound {
			t.Fatalf("%s: got %d", path, rr.Code)
		}
	}
}
