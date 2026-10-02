package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer is written by the helper's output copier while the test polls it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// The helper starts a real Postgres on this OS, loads the schema, answers
// -exec, and keeps its data across a restart. Run on macOS, Linux and Windows
// in CI.
func TestStartExecRestart(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "tutorial-db")
	if os.PathSeparator == '\\' {
		bin += ".exe"
	}
	if out, err := exec.Command("go", "build", "-buildvcs=false", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	dir := t.TempDir()
	const port = "54339"

	start := func() (*exec.Cmd, *syncBuffer) {
		t.Helper()
		out := &syncBuffer{}
		cmd := exec.Command(bin, "-port", port, "-dir", dir)
		cmd.Stdout, cmd.Stderr = out, out
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(3 * time.Minute)
		for !strings.Contains(out.String(), "ready on localhost:"+port) {
			if time.Now().After(deadline) {
				_ = cmd.Process.Kill()
				log, _ := os.ReadFile(filepath.Join(dir, "postgres.log"))
				t.Fatalf("not ready:\n%s\npostgres.log:\n%s", out.String(), log)
			}
			time.Sleep(200 * time.Millisecond)
		}
		return cmd, out
	}
	// stop with Ctrl-C where the OS can deliver it, and always with -stop,
	// which is the only way on Windows.
	stop := func(cmd *exec.Cmd, ctrlC bool) {
		t.Helper()
		if ctrlC && runtime.GOOS != "windows" {
			if err := cmd.Process.Signal(os.Interrupt); err != nil {
				t.Fatal(err)
			}
		} else if out, err := exec.Command(bin, "-dir", dir, "-stop").CombinedOutput(); err != nil {
			t.Fatalf("-stop: %v\n%s", err, out)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("helper exit: %v", err)
			}
		case <-time.After(30 * time.Second):
			_ = cmd.Process.Kill()
			t.Fatal("helper did not exit after the database stopped")
		}
	}
	execSQL := func(query string) string {
		t.Helper()
		out, err := exec.Command(bin, "-port", port, "-exec", query).CombinedOutput()
		if err != nil {
			t.Fatalf("exec %q: %v\n%s", query, err, out)
		}
		return string(out)
	}

	cmd, _ := start()
	execSQL("INSERT INTO orders (id, customer, status, total_cents) VALUES ('00000000-0000-0000-0000-000000000001', 'ada', 'placed', 100)")
	if got := execSQL("SELECT count(*) AS n FROM orders"); !strings.Contains(got, "\n1\n") {
		t.Fatalf("count after insert: %q", got)
	}
	stop(cmd, true)

	cmd, _ = start()
	defer stop(cmd, false)
	if got := execSQL("SELECT count(*) AS n FROM orders"); !strings.Contains(got, "\n1\n") {
		t.Fatalf("data did not survive a restart: %q", got)
	}
	if got := execSQL("SELECT count(*) AS n FROM order_items"); !strings.Contains(got, "\n0\n") {
		t.Fatalf("order_items: %q", got)
	}
}
