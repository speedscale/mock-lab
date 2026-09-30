package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestValidateAllowsTheDemoCalls(t *testing.T) {
	ok := []relayRequest{
		{Port: 8080, Method: "GET", Path: "/"},
		{Port: 4143, Method: "GET", Path: "/api/projects"},
		{Port: 8080, Method: "GET", Path: "/api/projects/kubernetes"},
		{Port: 8080, Method: "GET", Path: "/api/projects/chaos-mesh"},
		{Port: 8080, Method: "GET", Path: "/api/categories"},
		{Port: 8080, Method: "GET", Path: "/api/stats"},
		{Port: 4143, Method: "POST", Path: "/oauth/token"},
		{Port: 8080, Method: "POST", Path: "/api/orders", Body: `{"project":"kubernetes"}`},
		{Port: 8080, Method: "GET", Path: "/api/orders/order-abc123", Token: "abc"},
	}
	for _, req := range ok {
		if err := validate(req); err != nil {
			t.Errorf("validate(%+v) = %v", req, err)
		}
	}
}

func TestValidateRejectsAnythingElse(t *testing.T) {
	bad := []relayRequest{
		{Port: 9090, Method: "GET", Path: "/"},
		{Port: 8080, Method: "DELETE", Path: "/"},
		{Port: 8080, Method: "GET", Path: "/v1/projects"},
		{Port: 8080, Method: "GET", Path: "/api/../secret"},
		{Port: 8080, Method: "GET", Path: "http://example.com/"},
		{Port: 8080, Method: "GET", Path: "/api/projects/../"},
		{Port: 8080, Method: "POST", Path: "/api/orders", Token: "Bearer secret"},
		{Port: 8080, Method: "GET", Path: "/api/orders/order id"},
	}
	for _, req := range bad {
		if err := validate(req); err == nil {
			t.Errorf("validate(%+v) succeeded", req)
		}
	}
}

func TestForwardRoundTrip(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("User-Agent") != "mock-lab-dashboard" {
			t.Errorf("user agent = %q", r.Header.Get("User-Agent"))
		}
		switch r.URL.Path {
		case "/":
			_, _ = w.Write([]byte(`{"service":"ok"}`))
		case "/api/orders":
			if r.Method != http.MethodPost {
				t.Errorf("method = %s", r.Method)
			}
			if r.Header.Get("Authorization") != "Bearer secret-token" {
				t.Errorf("auth = %q", r.Header.Get("Authorization"))
			}
			if r.Header.Get("Content-Type") != "application/json" {
				t.Errorf("content-type = %q", r.Header.Get("Content-Type"))
			}
			b, _ := io.ReadAll(r.Body)
			if string(b) != `{"project":"kubernetes"}` {
				t.Errorf("body = %s", b)
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"order_id":"order-1"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()

	upstreamBase = upstream.URL
	t.Cleanup(func() { upstreamBase = "" })

	got := forward(relayRequest{Port: 8080, Method: "GET", Path: "/"})
	if got.Error != "" || got.Status != 200 || !strings.Contains(got.Body, `"service":"ok"`) {
		t.Fatalf("GET / = %+v", got)
	}

	got = forward(relayRequest{
		Port:   4143,
		Method: "POST",
		Path:   "/api/orders",
		Body:   `{"project":"kubernetes"}`,
		Token:  "secret-token",
	})
	if got.Error != "" || got.Status != 201 || !strings.Contains(got.Body, "order-1") {
		t.Fatalf("POST /api/orders = %+v", got)
	}
}

func TestForwardUnreachable(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	upstreamBase = "http://" + addr
	t.Cleanup(func() { upstreamBase = "" })

	got := forward(relayRequest{Port: 8080, Method: "GET", Path: "/"})
	if got.Error != "unreachable" || got.Status != 0 {
		t.Fatalf("got %+v", got)
	}
}

func TestRelayRejectsOtherPorts(t *testing.T) {
	srv := httptest.NewServer(newMux())
	defer srv.Close()

	res, err := http.Post(srv.URL+"/relay", "application/json", strings.NewReader(`{"port":9090,"method":"GET","path":"/"}`))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d", res.StatusCode)
	}
	var body relayResult
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Error != "bad_request" || !strings.Contains(body.Detail, "8080") {
		t.Fatalf("body = %+v", body)
	}
}

func TestTargetBaseUsesLocalhost(t *testing.T) {
	upstreamBase = ""
	if got := targetBase(4143); got != "http://localhost:4143" {
		t.Fatalf("targetBase = %s", got)
	}
}

func TestForwardTimeout(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(time.Second)
	}))
	defer upstream.Close()

	upstreamBase = upstream.URL
	old := client.Timeout
	client.Timeout = 100 * time.Millisecond
	t.Cleanup(func() {
		upstreamBase = ""
		client.Timeout = old
	})

	got := forward(relayRequest{Port: 8080, Method: "GET", Path: "/"})
	if got.Error != "timeout" {
		t.Fatalf("got %+v", got)
	}
}

func TestIndexOffersBothPorts(t *testing.T) {
	srv := httptest.NewServer(newMux())
	defer srv.Close()

	res, err := http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	page := string(b)
	for _, want := range []string{"8080", "4143", "proxymock", "/api/orders", "/oauth/token"} {
		if !strings.Contains(page, want) {
			t.Errorf("index missing %q", want)
		}
	}
}
