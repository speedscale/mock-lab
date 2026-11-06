package main

type project struct {
	Lifecycle string `json:"maturity"`
}

type projectStats struct {
	Total      int            `json:"total"`
	ByMaturity map[string]int `json:"by_maturity"`
}

func summarizeProjects(projects []project) projectStats {
	stats := projectStats{Total: len(projects), ByMaturity: map[string]int{}}
	for _, p := range projects {
		if p.Lifecycle != "" {
			stats.ByMaturity[p.Lifecycle]++
		}
	}
	return stats
}
