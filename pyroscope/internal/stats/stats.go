package stats

import "strings"

// Project is the subset of the downstream catalog record used by the API.
type Project struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
}

// Result is intentionally stable so a recorded response can act as a
// behavioral contract while the implementation is optimized.
type Result struct {
	TotalRecords      int            `json:"total_records"`
	ValidRecords      int            `json:"valid_records"`
	UniqueProjects    int            `json:"unique_projects"`
	DuplicatesRemoved int            `json:"duplicates_removed"`
	InvalidRecords    int            `json:"invalid_records"`
	ByCategory        map[string]int `json:"by_category"`
}

// Build validates, deduplicates, and aggregates a catalog response.
func Build(projects []Project) Result {
	unique, invalid := deduplicateProjects(projects)

	byCategory := make(map[string]int)
	for _, project := range unique {
		byCategory[project.Category]++
	}

	valid := len(projects) - invalid
	return Result{
		TotalRecords:      len(projects),
		ValidRecords:      valid,
		UniqueProjects:    len(unique),
		DuplicatesRemoved: valid - len(unique),
		InvalidRecords:    invalid,
		ByCategory:        byCategory,
	}
}

// deduplicateProjects preserves the first valid project for each ID.
func deduplicateProjects(projects []Project) ([]Project, int) {
	unique := make([]Project, 0, len(projects))
	seen := make(map[string]struct{}, len(projects))
	invalid := 0

	for _, project := range projects {
		if strings.TrimSpace(project.ID) == "" ||
			strings.TrimSpace(project.Name) == "" ||
			strings.TrimSpace(project.Category) == "" {
			invalid++
			continue
		}

		if _, duplicate := seen[project.ID]; duplicate {
			continue
		}

		seen[project.ID] = struct{}{}
		unique = append(unique, project)
	}

	return unique, invalid
}
