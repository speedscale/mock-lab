package main

import (
	"testing"
	"time"
)

func TestDurationFromEnv(t *testing.T) {
	t.Run("unset disables delay", func(t *testing.T) {
		t.Setenv("PROJECTS_DELAY", "")
		if got := durationFromEnv("PROJECTS_DELAY"); got != 0 {
			t.Fatalf("durationFromEnv() = %s, want 0", got)
		}
	})

	t.Run("parses Go duration", func(t *testing.T) {
		t.Setenv("PROJECTS_DELAY", "120ms")
		if got := durationFromEnv("PROJECTS_DELAY"); got != 120*time.Millisecond {
			t.Fatalf("durationFromEnv() = %s, want 120ms", got)
		}
	})
}
