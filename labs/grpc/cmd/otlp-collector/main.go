// otlp-collector receives OpenTelemetry traces over OTLP/gRPC and logs how
// many spans each export carried, standing in for an OpenTelemetry Collector.
package main

import (
	"context"
	"log"
	"net"
	"os"

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
	log.Printf("otlp collector listening on %s", lis.Addr())
	log.Fatal(srv.Serve(lis))
}
