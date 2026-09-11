package stats

import (
	"reflect"
	"testing"
)

func TestBuildPreservesFirstValidRecordAndCountsInvalidInput(t *testing.T) {
	projects := []Project{
		{ID: "one", Name: "first", Category: "runtime"},
		{ID: "two", Name: "second", Category: "database"},
		{ID: "one", Name: "later duplicate", Category: "other"},
		{ID: "", Name: "missing id", Category: "runtime"},
		{ID: "three", Name: "", Category: "runtime"},
	}

	got := Build(projects)
	want := Result{
		TotalRecords:      5,
		ValidRecords:      3,
		UniqueProjects:    2,
		DuplicatesRemoved: 1,
		InvalidRecords:    2,
		ByCategory: map[string]int{
			"runtime":  1,
			"database": 1,
		},
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Build() = %#v, want %#v", got, want)
	}
}

func BenchmarkBuild(b *testing.B) {
	projects := make([]Project, 0, 12_000)
	for i := 0; i < 10_000; i++ {
		project := Project{ID: string(rune(i + 1)), Name: "project", Category: "runtime"}
		projects = append(projects, project)
		if i%5 == 0 {
			projects = append(projects, project)
		}
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Build(projects)
	}
}
