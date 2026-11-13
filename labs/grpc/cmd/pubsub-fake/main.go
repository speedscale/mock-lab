// pubsub-fake serves the Google Cloud Pub/Sub API from memory, using the Go
// client library's own fake (pstest). It speaks the real google.pubsub.v1
// gRPC API, so recordings of it hold real Pub/Sub calls with no Google
// account, project or network.
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"cloud.google.com/go/pubsub/v2/pstest"
)

func main() {
	addr := ":8085"
	if port := os.Getenv("PORT"); port != "" {
		addr = ":" + port
	}
	// NewServerWithPort listens on loopback only; this listens on every
	// interface, so a container or another host can reach it too
	srv := pstest.NewServerWithAddress(addr)
	log.Printf("pubsub fake listening on %s", srv.Addr)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig
	_ = srv.Close()
}
