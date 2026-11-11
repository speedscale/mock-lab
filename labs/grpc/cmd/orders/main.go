// orders is the service under test: a gRPC order service. Creating an order
// publishes an event to Google Cloud Pub/Sub, and every call is traced with
// OpenTelemetry and exported over OTLP/gRPC, so a recording of it holds
// inbound calls, a public Google API and an OTLP export.
//
// Environment:
//
//	PORT          listen port (default 9090)
//	PUBSUB_ADDR   Pub/Sub endpoint (default localhost:8085)
//	OTLP_ADDR     OTLP/gRPC trace endpoint (default localhost:4317)
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"cloud.google.com/go/pubsub/v2"
	"cloud.google.com/go/pubsub/v2/apiv1/pubsubpb"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"google.golang.org/api/option"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/genproto/googleapis/type/money"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	ordersv1 "github.com/speedscale/mock-lab/grpc/gen/acme/orders/v1"
)

const (
	projectID = "acme-demo"
	topicID   = "order-events"
)

// epoch makes timestamps a function of the order number, so a replay returns
// the same bytes the recording holds.
var epoch = time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	tp, err := tracing(ctx, env("OTLP_ADDR", "localhost:4317"))
	if err != nil {
		log.Fatal(err)
	}
	publisher, closePubSub, err := orderEvents(ctx, env("PUBSUB_ADDR", "localhost:8085"))
	if err != nil {
		log.Fatal(err)
	}

	lis, err := net.Listen("tcp", ":"+env("PORT", "9090"))
	if err != nil {
		log.Fatal(err)
	}
	srv := grpc.NewServer(grpc.StatsHandler(otelgrpc.NewServerHandler()))
	ordersv1.RegisterOrdersServer(srv, &server{orders: map[string]*ordersv1.Order{}, publisher: publisher})
	healthpb.RegisterHealthServer(srv, health.NewServer())

	go func() {
		<-ctx.Done()
		srv.GracefulStop()
	}()
	log.Printf("orders listening on %s", lis.Addr())
	if err := srv.Serve(lis); err != nil {
		log.Print(err)
	}

	// flush the last spans and close Pub/Sub before exiting
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = tp.Shutdown(shutdownCtx)
	closePubSub()
}

func tracing(ctx context.Context, addr string) (*sdktrace.TracerProvider, error) {
	exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(addr), otlptracegrpc.WithInsecure())
	if err != nil {
		return nil, err
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter, sdktrace.WithBatchTimeout(2*time.Second)),
		sdktrace.WithResource(resource.NewWithAttributes(semconv.SchemaURL,
			semconv.ServiceName("orders"), semconv.ServiceVersion("1.4.2"))),
	)
	otel.SetTracerProvider(tp)
	return tp, nil
}

// orderEvents returns a publisher for the order-events topic, creating the
// topic if it does not exist yet.
func orderEvents(ctx context.Context, addr string) (*pubsub.Publisher, func(), error) {
	client, err := pubsub.NewClient(ctx, projectID,
		option.WithEndpoint(addr),
		option.WithoutAuthentication(),
		option.WithGRPCDialOption(grpc.WithTransportCredentials(insecure.NewCredentials())),
		option.WithGRPCConnectionPool(1),
	)
	if err != nil {
		return nil, nil, err
	}
	name := fmt.Sprintf("projects/%s/topics/%s", projectID, topicID)
	_, err = client.TopicAdminClient.GetTopic(ctx, &pubsubpb.GetTopicRequest{Topic: name})
	if status.Code(err) == codes.NotFound {
		_, err = client.TopicAdminClient.CreateTopic(ctx, &pubsubpb.Topic{Name: name})
	}
	if err != nil {
		return nil, nil, fmt.Errorf("pubsub: %w", err)
	}
	publisher := client.Publisher(name)
	publisher.EnableMessageOrdering = true
	return publisher, func() {
		publisher.Stop()
		_ = client.Close()
	}, nil
}

type server struct {
	ordersv1.UnimplementedOrdersServer

	mu     sync.Mutex
	orders map[string]*ordersv1.Order
	next   int

	publisher *pubsub.Publisher
}

func (s *server) CreateOrder(ctx context.Context, req *ordersv1.CreateOrderRequest) (*ordersv1.Order, error) {
	if err := validate(req); err != nil {
		return nil, err
	}

	order := &ordersv1.Order{
		CustomerId: req.GetCustomerId(),
		Items:      req.GetItems(),
		Total:      total(req.GetItems()),
		Status:     ordersv1.OrderStatus_ORDER_STATUS_PENDING,
	}
	for _, item := range req.GetItems() {
		order.WeightKg += 0.35 * float64(item.GetQuantity())
		order.WarehouseIds = append(order.WarehouseIds, warehouseFor(item.GetSku()))
	}
	switch f := req.GetFulfillment().(type) {
	case *ordersv1.CreateOrderRequest_ShipTo:
		order.Fulfillment = &ordersv1.Order_ShipTo{ShipTo: f.ShipTo}
	case *ordersv1.CreateOrderRequest_PickupStoreId:
		order.Fulfillment = &ordersv1.Order_PickupStoreId{PickupStoreId: f.PickupStoreId}
	}

	s.mu.Lock()
	s.next++
	order.OrderId = fmt.Sprintf("ord-%05d", s.next)
	order.CreatedAt = timestamppb.New(epoch.Add(time.Duration(s.next) * time.Minute))
	s.orders[order.OrderId] = order
	s.mu.Unlock()

	if err := s.publish(ctx, order); err != nil {
		return nil, status.Errorf(codes.Unavailable, "publish order event: %v", err)
	}
	return order, nil
}

// validate rejects an order with the details a client needs to fix it, in a
// google.rpc.BadRequest carried in the grpc-status-details-bin trailer.
func validate(req *ordersv1.CreateOrderRequest) error {
	var violations []*errdetails.BadRequest_FieldViolation
	if req.GetCustomerId() == "" {
		violations = append(violations, &errdetails.BadRequest_FieldViolation{Field: "customer_id", Description: "is required"})
	}
	if len(req.GetItems()) == 0 {
		violations = append(violations, &errdetails.BadRequest_FieldViolation{Field: "items", Description: "needs at least one item"})
	}
	for i, item := range req.GetItems() {
		if item.GetQuantity() <= 0 {
			violations = append(violations, &errdetails.BadRequest_FieldViolation{
				Field:       fmt.Sprintf("items[%d].quantity", i),
				Description: "must be positive",
			})
		}
	}
	if len(violations) == 0 {
		return nil
	}
	st, err := status.New(codes.InvalidArgument, "invalid order").WithDetails(
		&errdetails.BadRequest{FieldViolations: violations},
		&errdetails.ErrorInfo{Reason: "ORDER_INVALID", Domain: "orders.acme.dev", Metadata: map[string]string{"customer_id": req.GetCustomerId()}},
	)
	if err != nil {
		return err
	}
	return st.Err()
}

func total(items []*ordersv1.LineItem) *money.Money {
	var cents int64
	for _, item := range items {
		price := item.GetUnitPrice()
		cents += (price.GetUnits()*100 + int64(price.GetNanos()/10_000_000)) * int64(item.GetQuantity())
	}
	return &money.Money{CurrencyCode: "USD", Units: cents / 100, Nanos: int32(cents%100) * 10_000_000}
}

func warehouseFor(sku string) int32 {
	var h int32
	for _, c := range sku {
		h = h*31 + c
	}
	if h < 0 {
		h = -h
	}
	return 100 + h%7
}

func (s *server) publish(ctx context.Context, order *ordersv1.Order) error {
	ctx, span := otel.Tracer("orders").Start(ctx, "publish order.created")
	defer span.End()
	span.SetAttributes(attribute.String("order.id", order.GetOrderId()))

	data, err := proto.Marshal(order)
	if err != nil {
		return err
	}
	res := s.publisher.Publish(ctx, &pubsub.Message{
		Data:        data,
		Attributes:  map[string]string{"event": "order.created", "customer_id": order.GetCustomerId()},
		OrderingKey: order.GetCustomerId(),
	})
	_, err = res.Get(ctx)
	return err
}

func (s *server) GetOrder(_ context.Context, req *ordersv1.GetOrderRequest) (*ordersv1.Order, error) {
	order, err := s.lookup(req.GetOrderId())
	if err != nil {
		return nil, err
	}
	return order, nil
}

func (s *server) lookup(id string) (*ordersv1.Order, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	order, ok := s.orders[id]
	if !ok {
		st, err := status.New(codes.NotFound, "order not found").WithDetails(
			&errdetails.ResourceInfo{ResourceType: "acme.orders.v1.Order", ResourceName: id, Description: "no such order"},
		)
		if err != nil {
			return nil, err
		}
		return nil, st.Err()
	}
	return order, nil
}

func (s *server) WatchOrder(req *ordersv1.WatchOrderRequest, stream grpc.ServerStreamingServer[ordersv1.OrderEvent]) error {
	order, err := s.lookup(req.GetOrderId())
	if err != nil {
		return err
	}
	at := order.GetCreatedAt().AsTime()
	for i, step := range []struct {
		status ordersv1.OrderStatus
		note   string
	}{
		{ordersv1.OrderStatus_ORDER_STATUS_PENDING, "order received"},
		{ordersv1.OrderStatus_ORDER_STATUS_PAID, "payment captured"},
		{ordersv1.OrderStatus_ORDER_STATUS_SHIPPED, "handed to the carrier"},
	} {
		err := stream.Send(&ordersv1.OrderEvent{
			OrderId: order.GetOrderId(),
			Status:  step.status,
			Note:    step.note,
			At:      timestamppb.New(at.Add(time.Duration(i) * 5 * time.Minute)),
		})
		if errors.Is(err, context.Canceled) {
			return nil
		}
		if err != nil {
			return err
		}
	}
	return nil
}
