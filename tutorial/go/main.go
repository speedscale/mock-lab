// Command tutorial-orders is the Go port of the tutorial orders service.
// The behavior contract lives in ../contract/SPEC.md.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	log.SetFlags(0)

	port := env("PORT", "8080")
	dbURL := env("DATABASE_URL", "postgres://tutorial:tutorial@localhost:54329/tutorial?sslmode=disable")
	apiURL := env("DEMO_API_URL", "https://demo-api.trafficreplay.com")
	version := env("APP_VERSION", "v1")
	slow := os.Getenv("APP_SLOW") == "1"

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	store, err := NewPGStore(ctx, dbURL)
	if err != nil {
		log.Fatalf("database config: %v", err)
	}
	defer store.Close()

	app := &App{
		Store:    store,
		Upstream: NewUpstream(apiURL),
		Version:  version,
		Slow:     slow,
		Now:      time.Now,
	}

	handler := app.Routes()
	if os.Getenv("READINESS_FIXTURE") == "1" {
		fixture, err := newReadinessFixture(store.pool, apiURL)
		if err != nil {
			log.Fatal(err)
		}
		handler = fixture.handler(handler)
	}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("tutorial-orders (go) listening on :%s version=%s slow=%s", port, version, strconv.FormatBool(slow))

	drained := make(chan struct{})
	go func() {
		defer close(drained)
		<-ctx.Done()
		if os.Getenv("READINESS_FIXTURE") == "1" && defect("R23") {
			os.Exit(0)
		}
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-drained
}
