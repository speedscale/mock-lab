package catalog

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/sync/errgroup"
)

const (
	maxInventoryResponseBytes = 64 << 10
	maxConcurrentLookups      = 4
)

type InventoryItem struct {
	ProductID string `json:"product_id"`
	Available bool   `json:"available"`
	Quantity  int    `json:"quantity"`
}

type Result struct {
	Items          []InventoryItem `json:"items"`
	RequestedItems int             `json:"requested_items"`
	AvailableItems int             `json:"available_items"`
	TotalQuantity  int             `json:"total_quantity"`
}

type Service struct {
	client  *http.Client
	baseURL *url.URL
	tracer  trace.Tracer
}

func NewService(client *http.Client, baseURL string, tracer trace.Tracer) (*Service, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return nil, fmt.Errorf("parse inventory URL: %w", err)
	}
	if parsed.Scheme == "" || parsed.Host == "" {
		return nil, fmt.Errorf("inventory URL must include scheme and host")
	}

	return &Service{client: client, baseURL: parsed, tracer: tracer}, nil
}

// Build fetches inventory with bounded concurrency while preserving request
// order in the response.
func (s *Service) Build(ctx context.Context, productIDs []string) (Result, error) {
	items := make([]InventoryItem, len(productIDs))
	group, groupCtx := errgroup.WithContext(ctx)
	group.SetLimit(maxConcurrentLookups)
	for i, productID := range productIDs {
		i, productID := i, productID
		group.Go(func() error {
			item, err := s.fetchInventory(groupCtx, productID)
			if err != nil {
				return err
			}
			items[i] = item
			return nil
		})
	}
	if err := group.Wait(); err != nil {
		return Result{}, err
	}

	result := Result{Items: items, RequestedItems: len(items)}
	for _, item := range items {
		if item.Available {
			result.AvailableItems++
		}
		result.TotalQuantity += item.Quantity
	}
	return result, nil
}

func (s *Service) fetchInventory(ctx context.Context, productID string) (InventoryItem, error) {
	ctx, span := s.tracer.Start(ctx, "inventory.lookup", trace.WithAttributes(
		attribute.String("code.file.path", "internal/catalog/catalog.go"),
		attribute.String("code.function.name", "catalog.(*Service).fetchInventory"),
		attribute.String("catalog.product_id", productID),
		attribute.String("server.address", s.baseURL.Hostname()),
	))
	defer span.End()

	endpoint := *s.baseURL
	endpoint.Path = path.Join(s.baseURL.Path, "v1/inventory", url.PathEscape(productID))
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "build request")
		return InventoryItem{}, fmt.Errorf("build inventory request for %q: %w", productID, err)
	}

	response, err := s.client.Do(req)
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "request inventory")
		return InventoryItem{}, fmt.Errorf("fetch inventory for %q: %w", productID, err)
	}
	defer response.Body.Close()

	if response.StatusCode != http.StatusOK {
		err := fmt.Errorf("inventory for %q returned %s", productID, response.Status)
		span.RecordError(err)
		span.SetStatus(codes.Error, response.Status)
		return InventoryItem{}, err
	}

	var item InventoryItem
	if err := json.NewDecoder(io.LimitReader(response.Body, maxInventoryResponseBytes)).Decode(&item); err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "decode response")
		return InventoryItem{}, fmt.Errorf("decode inventory for %q: %w", productID, err)
	}
	if item.ProductID != productID {
		err := fmt.Errorf("inventory returned product %q for %q", item.ProductID, productID)
		span.RecordError(err)
		span.SetStatus(codes.Error, "product mismatch")
		return InventoryItem{}, err
	}

	return item, nil
}
