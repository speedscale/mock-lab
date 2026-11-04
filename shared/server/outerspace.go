package main

import (
	_ "embed"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
)

//go:embed data/outerspace.json
var outerspaceJSON []byte

func outerspaceObjects() (map[string]json.RawMessage, error) {
	var objects map[string]json.RawMessage
	err := json.Unmarshal(outerspaceJSON, &objects)
	return objects, err
}

func registerOuterspace(mux *http.ServeMux) error {
	objects, err := outerspaceObjects()
	if err != nil {
		return err
	}
	for path, body := range objects {
		mux.HandleFunc("GET /outerspace/"+path, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(append(body, '\n'))
		})
	}
	return nil
}

func exportOuterspace(dir string) error {
	objects, err := outerspaceObjects()
	if err != nil {
		return err
	}
	for path, body := range objects {
		out := filepath.Join(dir, "outerspace", filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(out, append(body, '\n'), 0o644); err != nil {
			return err
		}
	}
	return nil
}
