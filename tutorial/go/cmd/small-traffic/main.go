package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

func main() {
	target := flag.String("target", "http://127.0.0.1:8080", "owned app or recording proxy")
	improve := flag.Bool("improve", false, "add schema operations and error statuses")
	flag.Parse()
	client := &http.Client{Timeout: 10 * time.Second}
	token := os.Getenv("TUTORIAL_AUTH_TOKEN")
	call := func(method, path, body string, want int, auth bool) []byte {
		req, err := http.NewRequest(method, *target+path, bytes.NewBufferString(body))
		if err != nil {
			panic(err)
		}
		req.Header.Set("Content-Type", "application/json")
		if auth {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := client.Do(req)
		if err != nil {
			fmt.Fprintln(os.Stderr, "request failed")
			os.Exit(1)
		}
		defer response.Body.Close()
		data, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		if err != nil || response.StatusCode != want {
			fmt.Fprintf(os.Stderr, "%s %s status=%d, want=%d\n", method, path, response.StatusCode, want)
			os.Exit(1)
		}
		fmt.Printf("%s %s %d\n", method, path, response.StatusCode)
		return data
	}
	var ids []string
	for _, order := range []struct {
		customer, project string
		quantity, total   int
	}{{"fixture-alice", "kubernetes", 2, 2400}, {"fixture-bob", "flux", 1, 800}} {
		payload, _ := json.Marshal(map[string]any{"customer": order.customer, "items": []map[string]any{{"project_id": order.project, "quantity": order.quantity}}})
		var response struct {
			ID    string `json:"id"`
			Total int    `json:"total_cents"`
		}
		if err := json.Unmarshal(call("POST", "/orders", string(payload), 201, true), &response); err != nil || response.Total != order.total {
			fmt.Fprintln(os.Stderr, "order violates accepted pricing contract")
			os.Exit(1)
		}
		ids = append(ids, response.ID)
		call("GET", "/orders/"+response.ID, "", 200, true)
	}
	if !*improve {
		return
	}
	call("GET", "/catalog", "", 200, true)
	call("GET", "/orders/"+ids[0]+"/status", "", 200, true)
	call("GET", "/orders", "", 200, true)
	call("POST", "/orders", "{}", 400, true)
	call("GET", "/orders/not-a-uuid", "", 404, true)
	call("GET", "/orders", "", 401, false)
}
