package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/speedscale/mock-lab/pyroscope-demo/internal/stats"
)

const uniqueProjects = 12_000

type catalogResponse struct {
	Projects []stats.Project `json:"projects"`
}

func main() {
	address := envOrDefault("CATALOG_ADDR", ":8090")
	dataset := catalogResponse{Projects: buildDataset()}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("GET /v1/catalog", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(dataset); err != nil {
			log.Printf("encode catalog: %v", err)
		}
	})

	log.Printf("deterministic catalog listening on %s with %d records", address, len(dataset.Projects))
	log.Fatal(http.ListenAndServe(address, mux))
}

func buildDataset() []stats.Project {
	categories := []string{"runtime", "database", "observability", "security"}
	projects := make([]stats.Project, 0, uniqueProjects+(uniqueProjects/4)+120)

	for i := 0; i < uniqueProjects; i++ {
		project := stats.Project{
			ID:       fmt.Sprintf("project-%05d", i),
			Name:     fmt.Sprintf("Project %05d", i),
			Category: categories[i%len(categories)],
		}
		projects = append(projects, project)
		if i%4 == 0 {
			projects = append(projects, project)
		}
	}

	for i := 0; i < 120; i++ {
		projects = append(projects, stats.Project{
			ID:       "",
			Name:     fmt.Sprintf("Malformed %03d", i),
			Category: "invalid",
		})
	}

	return projects
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
