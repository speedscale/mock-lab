// Command tutorial-orders is the Go port of the tutorial orders service.
// The behavior contract lives in ../contract/SPEC.md.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
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
	dbURL := env("DATABASE_URL", "postgres://tutorial:tutorial@localhost:5432/tutorial?sslmode=disable")
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
		AuthToken: os.Getenv("TUTORIAL_AUTH_TOKEN"),
		Store:     store,
		Upstream:  NewUpstream(apiURL),
		Version:   version,
		Slow:      slow,
		Now:       time.Now,
	}

	app.Upstream.LatchFailures = os.Getenv("TUTORIAL_RECOVERY_DEFECT") == "1"

	if seed := os.Getenv("TUTORIAL_ID_SEED"); seed != "" {
		var sequence atomic.Uint64
		app.NewID = func() string {
			return uuid.NewSHA1(uuid.NameSpaceURL, []byte(fmt.Sprintf("%s/%d", seed, sequence.Add(1)))).String()
		}
	}
	if clock := os.Getenv("TUTORIAL_CLOCK"); clock != "" {
		fixed, err := time.Parse(time.RFC3339, clock)
		if err != nil {
			log.Fatal("invalid TUTORIAL_CLOCK")
		}
		app.Now = func() time.Time { return fixed }
	}
	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           app.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("tutorial-orders (go) listening on :%s version=%s slow=%s", port, version, strconv.FormatBool(slow))

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
