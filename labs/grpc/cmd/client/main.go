// client drives the orders service with a fixed sequence of calls, so every
// recording holds the same calls in the same order: a health check, orders
// shipped and picked up, a rejected order, lookups and a status stream.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"time"

	"google.golang.org/genproto/googleapis/type/money"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"

	ordersv1 "github.com/speedscale/mock-lab/grpc/gen/acme/orders/v1"
)

func main() {
	addr := flag.String("addr", "localhost:4143", "orders address (proxymock's inbound port while recording)")
	flag.Parse()

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	orders := ordersv1.NewOrdersClient(conn)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	res, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{})
	report("Health/Check", res.GetStatus().String(), err)

	usd := func(units int64, nanos int32) *money.Money {
		return &money.Money{CurrencyCode: "USD", Units: units, Nanos: nanos}
	}
	requests := []*ordersv1.CreateOrderRequest{
		{
			CustomerId: "cust-1001",
			Items: []*ordersv1.LineItem{
				{Sku: "SKU-MUG-01", Quantity: 2, UnitPrice: usd(12, 500000000)},
				{Sku: "SKU-TEE-M", Quantity: 1, UnitPrice: usd(24, 0)},
			},
			Fulfillment: &ordersv1.CreateOrderRequest_ShipTo{ShipTo: &ordersv1.Address{
				Line1: "1 Market St", City: "San Francisco", PostalCode: "94105", CountryCode: "US",
			}},
		},
		{
			CustomerId:  "cust-1002",
			Items:       []*ordersv1.LineItem{{Sku: "SKU-HOODIE-L", Quantity: 1, UnitPrice: usd(48, 990000000)}},
			Fulfillment: &ordersv1.CreateOrderRequest_PickupStoreId{PickupStoreId: "store-sfo-3"},
		},
		{
			// rejected: no customer and a zero quantity
			Items: []*ordersv1.LineItem{{Sku: "SKU-STICKER", Quantity: 0, UnitPrice: usd(3, 0)}},
		},
		{
			CustomerId: "cust-1003",
			Items: []*ordersv1.LineItem{
				{Sku: "SKU-STICKER", Quantity: 10, UnitPrice: usd(3, 0)},
				{Sku: "SKU-MUG-01", Quantity: 1, UnitPrice: usd(12, 500000000)},
				{Sku: "SKU-TEE-M", Quantity: 3, UnitPrice: usd(24, 0)},
			},
			Fulfillment: &ordersv1.CreateOrderRequest_ShipTo{ShipTo: &ordersv1.Address{
				Line1: "500 Pine St", City: "Seattle", PostalCode: "98101", CountryCode: "US",
			}},
		},
	}

	var created []string
	for _, req := range requests {
		order, err := orders.CreateOrder(ctx, req)
		report("CreateOrder", order.GetOrderId(), err)
		if err == nil {
			created = append(created, order.GetOrderId())
		}
	}
	for _, id := range append(created, "ord-99999") {
		order, err := orders.GetOrder(ctx, &ordersv1.GetOrderRequest{OrderId: id})
		report("GetOrder", fmt.Sprintf("%s %s", id, order.GetStatus()), err)
	}
	if len(created) > 0 {
		watch(ctx, orders, created[0])
	}
}

func watch(ctx context.Context, orders ordersv1.OrdersClient, id string) {
	stream, err := orders.WatchOrder(ctx, &ordersv1.WatchOrderRequest{OrderId: id})
	if err != nil {
		report("WatchOrder", id, err)
		return
	}
	for {
		event, err := stream.Recv()
		if err == io.EOF {
			return
		}
		report("WatchOrder", fmt.Sprintf("%s %s", id, event.GetStatus()), err)
		if err != nil {
			return
		}
	}
}

func report(call, detail string, err error) {
	if err != nil {
		log.Printf("%-12s %s: %s", call, status.Code(err), status.Convert(err).Message())
		return
	}
	log.Printf("%-12s %s", call, detail)
}
