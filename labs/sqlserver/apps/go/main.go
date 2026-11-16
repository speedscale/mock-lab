// Command shop is the Go version of the sqlserver lab's shop API, on go-mssqldb.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"

	mssql "github.com/microsoft/go-mssqldb"
)

type product struct {
	ID         int    `json:"id"`
	SKU        string `json:"sku"`
	Name       string `json:"name"`
	PriceCents int    `json:"price_cents"`
	Stock      int    `json:"stock"`
}

type order struct {
	ID         int    `json:"id"`
	ProductID  int    `json:"product_id"`
	Name       string `json:"name,omitempty"`
	Quantity   int    `json:"quantity"`
	TotalCents int    `json:"total_cents"`
}

type seller struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Sold int    `json:"sold"`
}

var errNotFound = errors.New("not found")
var errOutOfStock = errors.New("out of stock")

func env(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func main() {
	q := url.Values{}
	q.Set("database", env("DB_NAME", "shop"))
	q.Set("encrypt", "true")
	q.Set("TrustServerCertificate", "true")
	q.Set("app name", "shop-go")
	dsn := url.URL{
		Scheme:   "sqlserver",
		User:     url.UserPassword(env("DB_USER", "app"), env("DB_PASSWORD", "Lab-App-2026!")),
		Host:     env("DB_HOST", "localhost") + ":" + env("DB_PORT", "11433"),
		RawQuery: q.Encode(),
	}
	db, err := sql.Open("sqlserver", dsn.String())
	if err != nil {
		log.Fatal(err)
	}
	db.SetMaxOpenConns(4)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		var one int
		if err := db.QueryRowContext(r.Context(), "SELECT 1").Scan(&one); err != nil {
			fail(w, err)
			return
		}
		reply(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /products", func(w http.ResponseWriter, r *http.Request) {
		rows, err := db.QueryContext(r.Context(),
			"SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE category = @category ORDER BY id",
			sql.Named("category", r.URL.Query().Get("category")))
		if err != nil {
			fail(w, err)
			return
		}
		defer rows.Close()
		products := []product{}
		for rows.Next() {
			var p product
			if err := rows.Scan(&p.ID, &p.SKU, &p.Name, &p.PriceCents, &p.Stock); err != nil {
				fail(w, err)
				return
			}
			products = append(products, p)
		}
		if err := rows.Err(); err != nil {
			fail(w, err)
			return
		}
		reply(w, http.StatusOK, map[string]any{"products": products})
	})
	mux.HandleFunc("GET /products/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, ok := pathID(w, r)
		if !ok {
			return
		}
		var p product
		err := db.QueryRowContext(r.Context(),
			"SELECT id, sku, name, price_cents, stock FROM dbo.products WHERE id = @id", sql.Named("id", id)).
			Scan(&p.ID, &p.SKU, &p.Name, &p.PriceCents, &p.Stock)
		if errors.Is(err, sql.ErrNoRows) {
			reply(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if err != nil {
			fail(w, err)
			return
		}
		reply(w, http.StatusOK, p)
	})
	mux.HandleFunc("POST /orders", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			ProductID int `json:"product_id"`
			Quantity  int `json:"quantity"`
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || in.ProductID <= 0 || in.Quantity <= 0 {
			reply(w, http.StatusBadRequest, map[string]string{"error": "bad request"})
			return
		}
		o, err := placeOrder(r.Context(), db, in.ProductID, in.Quantity)
		switch {
		case errors.Is(err, errNotFound):
			reply(w, http.StatusNotFound, map[string]string{"error": "not found"})
		case errors.Is(err, errOutOfStock):
			reply(w, http.StatusConflict, map[string]string{"error": "out of stock"})
		case err != nil:
			fail(w, err)
		default:
			reply(w, http.StatusCreated, o)
		}
	})
	mux.HandleFunc("GET /orders/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, ok := pathID(w, r)
		if !ok {
			return
		}
		var o order
		err := db.QueryRowContext(r.Context(),
			"SELECT o.id, o.product_id, p.name, o.quantity, o.total_cents FROM dbo.orders o "+
				"JOIN dbo.products p ON p.id = o.product_id WHERE o.id = @id", sql.Named("id", id)).
			Scan(&o.ID, &o.ProductID, &o.Name, &o.Quantity, &o.TotalCents)
		if errors.Is(err, sql.ErrNoRows) {
			reply(w, http.StatusNotFound, map[string]string{"error": "not found"})
			return
		}
		if err != nil {
			fail(w, err)
			return
		}
		reply(w, http.StatusOK, o)
	})
	mux.HandleFunc("GET /reports/top-products", func(w http.ResponseWriter, r *http.Request) {
		limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
		if err != nil || limit <= 0 {
			limit = 3
		}
		var total int
		var status mssql.ReturnStatus
		rows, err := db.QueryContext(r.Context(), "dbo.top_products",
			sql.Named("limit", limit), sql.Named("total", sql.Out{Dest: &total}), &status)
		if err != nil {
			fail(w, err)
			return
		}
		top := []seller{}
		for rows.Next() {
			var s seller
			if err := rows.Scan(&s.ID, &s.Name, &s.Sold); err != nil {
				rows.Close()
				fail(w, err)
				return
			}
			top = append(top, s)
		}
		// the output parameter arrives after the last row, so it is set only once the rows are closed
		if err := rows.Close(); err != nil {
			fail(w, err)
			return
		}
		reply(w, http.StatusOK, map[string]any{"orders": total, "top": top})
	})

	addr := ":" + env("PORT", "8080")
	log.Printf("shop-go listening on %s, database %s", addr, dsn.Host)
	log.Fatal(http.ListenAndServe(addr, mux))
}

// placeOrder takes the stock and records the order in one transaction, so two orders cannot sell the same unit.
func placeOrder(ctx context.Context, db *sql.DB, productID, quantity int) (order, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return order{}, err
	}
	defer func() { _ = tx.Rollback() }()

	var price, stock int
	err = tx.QueryRowContext(ctx, "SELECT price_cents, stock FROM dbo.products WITH (UPDLOCK) WHERE id = @id",
		sql.Named("id", productID)).Scan(&price, &stock)
	if errors.Is(err, sql.ErrNoRows) {
		return order{}, errNotFound
	}
	if err != nil {
		return order{}, err
	}
	if stock < quantity {
		return order{}, errOutOfStock
	}
	if _, err := tx.ExecContext(ctx, "UPDATE dbo.products SET stock = stock - @quantity WHERE id = @id",
		sql.Named("quantity", quantity), sql.Named("id", productID)); err != nil {
		return order{}, err
	}
	o := order{ProductID: productID, Quantity: quantity, TotalCents: price * quantity}
	if err := tx.QueryRowContext(ctx,
		"INSERT INTO dbo.orders (product_id, quantity, total_cents) OUTPUT INSERTED.id VALUES (@id, @quantity, @total)",
		sql.Named("id", productID), sql.Named("quantity", quantity), sql.Named("total", o.TotalCents)).Scan(&o.ID); err != nil {
		return order{}, err
	}
	return o, tx.Commit()
}

func pathID(w http.ResponseWriter, r *http.Request) (int, bool) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil || id <= 0 {
		reply(w, http.StatusBadRequest, map[string]string{"error": "bad request"})
		return 0, false
	}
	return id, true
}

func reply(w http.ResponseWriter, status int, body any) {
	b, err := json.Marshal(body)
	if err != nil {
		status, b = http.StatusInternalServerError, []byte(`{"error":"internal"}`)
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(b)
}

func fail(w http.ResponseWriter, err error) {
	log.Print(err)
	reply(w, http.StatusInternalServerError, map[string]string{"error": fmt.Sprint("database: ", err)})
}
