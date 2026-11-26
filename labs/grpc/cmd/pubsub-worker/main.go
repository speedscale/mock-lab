// pubsub-worker seeds order events and processes them using StreamingPull.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"time"

	"cloud.google.com/go/pubsub/v2/apiv1/pubsubpb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const topic = "projects/demo/topics/orders"
const subscription = "projects/demo/subscriptions/orders-worker"

type orderEvent struct {
	OrderID string `json:"orderId"`
	Amount  int    `json:"amount"`
}

func main() {
	addr := flag.String("addr", "localhost:8085", "local plaintext Pub/Sub address")
	count := flag.Int("count", 3, "number of distinct messages to acknowledge")
	nackFirst := flag.Bool("nack-first", false, "nack the first delivery and require the mock to redeliver it")
	flag.Parse()
	if *count < 1 {
		log.Fatal("-count must be positive")
	}
	if err := run(*addr, flag.Arg(0), *count, *nackFirst); err != nil {
		log.Fatal(err)
	}
}

func run(addr, mode string, count int, nackFirst bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer conn.Close()
	publisher := pubsubpb.NewPublisherClient(conn)
	subscriber := pubsubpb.NewSubscriberClient(conn)

	switch mode {
	case "setup":
		if _, err := publisher.CreateTopic(ctx, &pubsubpb.Topic{Name: topic}); err != nil {
			return err
		}
		_, err := subscriber.CreateSubscription(ctx, &pubsubpb.Subscription{
			Name: subscription, Topic: topic, AckDeadlineSeconds: 10,
		})
		return err
	case "seed":
		return seed(ctx, publisher)
	case "consume":
		return consume(ctx, subscriber, count, nackFirst)
	default:
		return fmt.Errorf("usage: pubsub-worker [flags] setup|seed|consume")
	}
}

func seed(ctx context.Context, publisher pubsubpb.PublisherClient) error {
	for i := 1; i <= 3; i++ {
		if i > 1 {
			time.Sleep(400 * time.Millisecond)
		}
		event := orderEvent{OrderID: fmt.Sprintf("ord-%03d", i), Amount: i * 1250}
		data, err := json.Marshal(event)
		if err != nil {
			return err
		}
		_, err = publisher.Publish(ctx, &pubsubpb.PublishRequest{
			Topic: topic,
			Messages: []*pubsubpb.PubsubMessage{{
				Data: data, Attributes: map[string]string{"eventType": "order.created"},
			}},
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func consume(ctx context.Context, subscriber pubsubpb.SubscriberClient, count int, nackFirst bool) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	stream, err := subscriber.StreamingPull(ctx)
	if err != nil {
		return err
	}
	if err := stream.Send(&pubsubpb.StreamingPullRequest{
		Subscription: subscription, StreamAckDeadlineSeconds: 10, MaxOutstandingMessages: 1,
	}); err != nil {
		return err
	}
	fmt.Println("StreamingPull opened")

	acked := make(map[string]bool, count)
	var nackedID, oldAckID string
	redelivered := false
	for len(acked) < count || (nackFirst && !redelivered) {
		response, err := stream.Recv()
		if err != nil {
			return fmt.Errorf("receive after acknowledging %d of %d messages: %w", len(acked), count, err)
		}
		for _, delivery := range response.GetReceivedMessages() {
			message := delivery.GetMessage()
			id, ackID := message.GetMessageId(), delivery.GetAckId()
			if id == "" || ackID == "" || acked[id] {
				return fmt.Errorf("unexpected delivery with message ID %q and ack ID %q", id, ackID)
			}
			var event orderEvent
			if err := json.Unmarshal(message.GetData(), &event); err != nil {
				return fmt.Errorf("decode order event: %w", err)
			}
			if event.OrderID == "" || event.Amount <= 0 || message.GetAttributes()["eventType"] != "order.created" {
				return fmt.Errorf("invalid order event: %+v", event)
			}
			if nackFirst && nackedID == "" {
				nackedID, oldAckID = id, ackID
				if _, err := subscriber.ModifyAckDeadline(ctx, &pubsubpb.ModifyAckDeadlineRequest{
					Subscription: subscription, AckIds: []string{ackID}, AckDeadlineSeconds: 0,
				}); err != nil {
					return err
				}
				fmt.Printf("NACK order=%s message=%s\n", event.OrderID, id)
				continue
			}
			if id == nackedID {
				attempt := delivery.GetDeliveryAttempt()
				if ackID == oldAckID || attempt != 2 {
					return fmt.Errorf("redelivery for %s should have a fresh ack ID and attempt 2, got attempt %d", id, attempt)
				}
				redelivered = true
				fmt.Printf("REDELIVERED order=%s message=%s attempt=%d fresh_ack_id=true\n", event.OrderID, id, attempt)
			}
			if _, err := subscriber.Acknowledge(ctx, &pubsubpb.AcknowledgeRequest{
				Subscription: subscription, AckIds: []string{ackID},
			}); err != nil {
				return err
			}
			acked[id] = true
			fmt.Printf("ACK order=%s message=%s\n", event.OrderID, id)
		}
	}
	fmt.Printf("ACKED %d messages\n", len(acked))
	return nil
}
