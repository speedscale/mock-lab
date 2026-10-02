package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type project struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Maturity string `json:"maturity"`
}

var projects = []project{
	{"kubernetes", "Kubernetes", "Graduated"},
	{"flux", "Flux", "Incubating"},
	{"sandbox", "Sandbox", "Sandbox"},
}

func routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("GET /v1/projects", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(projects)
	})
	mux.HandleFunc("GET /v1/project/{id}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		for _, p := range projects {
			if p.ID == r.PathValue("id") {
				json.NewEncoder(w).Encode(p)
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)
		json.NewEncoder(w).Encode(map[string]string{"error": "unknown project"})
	})
	return mux
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8081"
	}
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, routes()))
}
