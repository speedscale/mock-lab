package main

import (
	"strings"
	"testing"
)

func TestDecodeCatalogRequestValidatesInput(t *testing.T) {
	tests := []struct {
		name string
		body string
		want []string
	}{
		{name: "valid", body: `{"product_ids":["sku-001","sku-002"]}`, want: []string{"sku-001", "sku-002"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := decodeCatalogRequest(strings.NewReader(test.body))
			if err != nil {
				t.Fatal(err)
			}
			if strings.Join(got.ProductIDs, ",") != strings.Join(test.want, ",") {
				t.Fatalf("ProductIDs = %v, want %v", got.ProductIDs, test.want)
			}
		})
	}
}

func TestDecodeCatalogRequestRejectsUnsafeShapes(t *testing.T) {
	tests := []string{
		`{"product_ids":[]}`,
		`{"product_ids":["sku-001","sku-001"]}`,
		`{"product_ids":[""]}`,
		`{"product_ids":["sku-001"],"unexpected":true}`,
	}
	for _, body := range tests {
		if _, err := decodeCatalogRequest(strings.NewReader(body)); err == nil {
			t.Fatalf("decodeCatalogRequest(%s) error = nil", body)
		}
	}
}
