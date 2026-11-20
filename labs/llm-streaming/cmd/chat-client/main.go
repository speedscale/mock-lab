// chat-client sends a small mix of streamed chat requests to an LLM server,
// the way an application in front of a model would. Point it at proxymock's
// recording port to capture realistic traffic for a replay.
//
// The default scenario sends plain questions, which is enough to measure
// streaming latency. The "eval" scenario sends the requests of an assistant
// that can call tools: every request carries tool definitions, so the model
// answers some with a tool call and the rest in writing.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

const systemPrompt = "You are the support assistant for a cloud-native storefront. " +
	"Answer in two sentences and cite the order or ticket number when one is given."

// prompts vary in length on purpose: real traffic mixes one-line questions
// with pasted logs and long context.
var prompts = []string{
	"Where is order 48213?",
	"Can I change the shipping address on order 77120 before it leaves the warehouse?",
	"Summarize this ticket: the customer reports that checkout fails with a 502 after applying a gift card, " +
		"retrying works about half the time, and the issue started after Tuesday's release.",
	"What is your return policy for opened electronics?",
	"Translate to Spanish: Your refund was issued and should appear within five business days.",
	"Here is the error from my integration, what does it mean? " +
		"POST /v2/carts/9921/items returned 409 Conflict {\"error\":\"inventory_reserved\",\"sku\":\"SSC-4110\",\"retryAfter\":30}",
	"Which plan includes priority support?",
	"Draft a short apology for a delayed order 31007 and offer free shipping on the next purchase.",
}

// evalPrompts are what a shopper asks an assistant that can look orders up.
// Three name an order, which the model answers with a get_order call.
var evalPrompts = []string{
	"Where is order 48213?",
	"What is your return policy for opened electronics?",
	"Can I change the shipping address on order 77120 before it leaves the warehouse?",
	"Which plan includes priority support?",
	"Has order 31007 shipped yet?",
	"How long does a refund take to appear on my card?",
	"Translate to Spanish: Your refund was issued and should appear within five business days.",
	"Summarize this ticket: the customer reports that checkout fails with a 502 after applying a gift card, " +
		"retrying works about half the time, and the issue started after Tuesday's release.",
}

// tool is one function the assistant may call, described once and written in
// each format's own shape by build.
type tool struct {
	name, description string
	parameters        map[string]any
}

var evalTools = []tool{
	{name: "get_order", description: "Look up the status and shipping details of an order.",
		parameters: map[string]any{"type": "object", "required": []string{"order_id"},
			"properties": map[string]any{"order_id": map[string]string{"type": "integer", "description": "The order number."}}}},
	{name: "search_help_center", description: "Search the help center articles.",
		parameters: map[string]any{"type": "object", "required": []string{"query"},
			"properties": map[string]any{"query": map[string]string{"type": "string", "description": "What to search for."}}}},
}

func main() {
	base := flag.String("url", "http://localhost:4143", "server base URL (proxymock's recording port by default)")
	format := flag.String("format", "openai", "openai, anthropic, ollama or bedrock")
	scenario := flag.String("scenario", "timing", "timing (plain questions) or eval (an assistant with tools)")
	n := flag.Int("n", 8, "number of requests to send")
	usage := flag.Bool("usage", true, "ask OpenAI-compatible servers for a usage report (stream_options.include_usage)")
	flag.Parse()
	includeUsage = *usage
	switch *scenario {
	case "timing":
	case "eval":
		prompts, tools = evalPrompts, evalTools
	default:
		fmt.Fprintf(os.Stderr, "unknown scenario %q\n", *scenario)
		os.Exit(2)
	}

	client := &http.Client{Timeout: 60 * time.Second}
	for i := 0; i < *n; i++ {
		prompt := prompts[i%len(prompts)]
		path, body := build(*format, prompt)
		req, err := http.NewRequest(http.MethodPost, *base+path, bytes.NewReader(body))
		if err != nil {
			log.Fatalf("request %d: %v", i+1, err)
		}
		req.Header.Set("Content-Type", "application/json")
		authorize(*format, req.Header)
		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			log.Fatalf("request %d: %v", i+1, err)
		}
		first, total := readTimed(resp.Body)
		resp.Body.Close()
		fmt.Printf("%-9s %3d  first byte %6.1f ms  done %6.1f ms  %5d bytes  %q\n",
			*format, resp.StatusCode, ms(first.Sub(start)), ms(time.Since(start)), total, short(prompt))
	}
}

var includeUsage = true

// apiKey is a lab value, not a secret. It stands for the production
// credential a real application would send.
const apiKey = "lab-production-key"

// authorize adds the headers a client of each API sends. Ollama takes no key,
// and a Bedrock request is signed, which this client does not do.
func authorize(format string, h http.Header) {
	switch format {
	case "openai":
		h.Set("Authorization", "Bearer "+apiKey)
	case "anthropic":
		h.Set("x-api-key", apiKey)
		h.Set("anthropic-version", "2023-06-01")
	}
}

// tools are sent with every request when the scenario has any.
var tools []tool

func build(format, prompt string) (string, []byte) {
	var path string
	var req map[string]any
	switch format {
	case "openai":
		path = "/v1/chat/completions"
		req = map[string]any{"model": "lab-model", "stream": true,
			"messages": []any{
				map[string]string{"role": "system", "content": systemPrompt},
				map[string]string{"role": "user", "content": prompt},
			}}
		if includeUsage {
			req["stream_options"] = map[string]any{"include_usage": true}
		}
	case "anthropic":
		path = "/v1/messages"
		req = map[string]any{"model": "lab-model", "stream": true, "max_tokens": 256, "system": systemPrompt,
			"messages": []any{map[string]string{"role": "user", "content": prompt}}}
	case "ollama":
		path = "/api/chat"
		req = map[string]any{"model": "lab-model", "stream": true,
			"messages": []any{
				map[string]string{"role": "system", "content": systemPrompt},
				map[string]string{"role": "user", "content": prompt},
			}}
	case "bedrock":
		path = "/model/lab-model/converse-stream"
		req = map[string]any{
			"system":   []any{map[string]string{"text": systemPrompt}},
			"messages": []any{map[string]any{"role": "user", "content": []any{map[string]string{"text": prompt}}}},
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown format %q\n", format)
		os.Exit(2)
	}
	if len(tools) > 0 {
		addTools(format, req)
	}
	b, _ := json.Marshal(req)
	return path, b
}

// addTools writes the tool definitions into a request the way its format
// spells them.
func addTools(format string, req map[string]any) {
	var defs []any
	for _, t := range tools {
		switch format {
		case "anthropic":
			defs = append(defs, map[string]any{"name": t.name, "description": t.description, "input_schema": t.parameters})
		case "bedrock":
			defs = append(defs, map[string]any{"toolSpec": map[string]any{
				"name": t.name, "description": t.description, "inputSchema": map[string]any{"json": t.parameters}}})
		default:
			defs = append(defs, map[string]any{"type": "function", "function": map[string]any{
				"name": t.name, "description": t.description, "parameters": t.parameters}})
		}
	}
	if format == "bedrock" {
		req["toolConfig"] = map[string]any{"tools": defs}
		return
	}
	req["tools"] = defs
}

// readTimed drains a streamed body and returns when its first bytes arrived
// and how many bytes it carried.
func readTimed(r io.Reader) (time.Time, int) {
	buf := make([]byte, 4096)
	var first time.Time
	total := 0
	for {
		n, err := r.Read(buf)
		if n > 0 && first.IsZero() {
			first = time.Now()
		}
		total += n
		if err != nil {
			return first, total
		}
	}
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func short(s string) string {
	if len(s) > 40 {
		return s[:37] + "..."
	}
	return s
}
