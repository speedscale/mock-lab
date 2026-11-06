package main

import (
	"reflect"
	"testing"
)

func TestSummarizeProjects(t *testing.T) {
	projects := []project{
		{Lifecycle: "Graduated"},
		{Lifecycle: "Graduated"},
		{Lifecycle: "Sandbox"},
		{},
	}
	got := summarizeProjects(projects)
	want := projectStats{Total: 4, ByMaturity: map[string]int{"Graduated": 2, "Sandbox": 1}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("summarizeProjects() = %#v, want %#v", got, want)
	}
}
