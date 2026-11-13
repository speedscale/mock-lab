// otlp-collector receives OpenTelemetry traces over OTLP/gRPC and logs how
// many spans each export carried, standing in for an OpenTelemetry Collector.
package main

import (
	"context"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	collectortrace "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	"google.golang.org/grpc"
)

type receiver struct {
	collectortrace.UnimplementedTraceServiceServer
}

func (receiver) Export(_ context.Context, req *collectortrace.ExportTraceServiceRequest) (*collectortrace.ExportTraceServiceResponse, error) {
	spans := 0
	for _, rs := range req.GetResourceSpans() {
		for _, ss := range rs.GetScopeSpans() {
			spans += len(ss.GetSpans())
		}
	}
	log.Printf("received %d spans", spans)
	return &collectortrace.ExportTraceServiceResponse{}, nil
}

func main() {
	addr := ":4317"
	if port := os.Getenv("PORT"); port != "" {
		addr = ":" + port
	}
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}
	srv := grpc.NewServer()
	collectortrace.RegisterTraceServiceServer(srv, receiver{})
	// A script's background jobs start with SIGINT ignored, and Go keeps that
	// disposition unless the signal is registered, so register it explicitly.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		srv.GracefulStop()
	}()
	log.Printf("otlp collector listening on %s", lis.Addr())
	if err := srv.Serve(lis); err != nil {
		log.Fatal(err)
	}
}
