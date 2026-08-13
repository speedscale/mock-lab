// The checkout API binary that proxymock wraps during record and replay. It
// writes structured JSON logs to a file that Grafana Alloy tails into Loki.
package main

import (
	"context"
	"errors"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/speedscale/mock-lab/loki-demo/internal/checkout"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logPath := envOrDefault("LOG_FILE", "scratch/logs/checkout.log")
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		log.Fatalf("create log directory: %v", err)
	}
	logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Fatalf("open log file: %v", err)
	}
	defer func() { _ = logFile.Close() }()

	// Log timestamps are emitted in UTC so a line can be lined up with the UTC
	// interval a replay publishes in its window.json.
	logger := slog.New(slog.NewJSONHandler(logFile, &slog.HandlerOptions{
		Level: slog.LevelInfo,
		ReplaceAttr: func(_ []string, attr slog.Attr) slog.Attr {
			if attr.Key == slog.TimeKey {
				attr.Value = slog.StringValue(attr.Value.Time().UTC().Format(time.RFC3339Nano))
			}
			return attr
		},
	}))
	service := checkout.NewService(envOrDefault("PRICING_URL", "http://localhost:8090"), logger)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.Handle("GET /api/quote", service.Handler())

	server := &http.Server{
		Addr:              envOrDefault("APP_ADDR", ":8080"),
		Handler:           mux,
		ReadHeaderTimeout: 2 * time.Second,
	}

	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutdown server: %v", err)
		}
	}()

	log.Printf("checkout API listening on %s, structured logs at %s", server.Addr, logPath)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
