package main

import (
	"embed"
	"net/http"
	"os"
	"path/filepath"
)

//go:embed data/spacex
var spaceXData embed.FS

var spaceXPaths = []string{
	"/spacex/v5/launches/latest",
	"/spacex/v4/ships/614251b711a64135defb3654",
	"/spacex/v4/ships/5ea6ed30080df4000697c916",
	"/spacex/v4/ships/618fad7e563d69573ed8caa9",
}

func serveSpaceX(w http.ResponseWriter, r *http.Request) {
	for _, path := range spaceXPaths {
		if r.URL.Path != path {
			continue
		}
		body, err := spaceXData.ReadFile("data" + path + ".json")
		if err != nil {
			http.Error(w, `{"error":"dataset unavailable"}`, http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusNotFound)
	_, _ = w.Write([]byte(`{"error":"not found"}`))
}

func exportSpaceX(dir string) error {
	for _, path := range spaceXPaths {
		body, err := spaceXData.ReadFile("data" + path + ".json")
		if err != nil {
			return err
		}
		out := filepath.Join(dir, path[1:])
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(out, body, 0o644); err != nil {
			return err
		}
	}
	return nil
}
