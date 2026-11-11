// chat-client sends a small mix of streamed chat requests to an LLM server,
// the way an application in front of a model would. Point it at proxymock's
// recording port to capture realistic traffic for a replay.
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

func main() {
	base := flag.String("url", "http://localhost:4143", "server base URL (proxymock's recording port by default)")
	format := flag.String("format", "openai", "openai, anthropic, ollama or bedrock")
	n := flag.Int("n", 8, "number of requests to send")
	usage := flag.Bool("usage", true, "ask OpenAI-compatible servers for a usage report (stream_options.include_usage)")
	flag.Parse()
	includeUsage = *usage

	client := &http.Client{Timeout: 60 * time.Second}
	for i := 0; i < *n; i++ {
		prompt := prompts[i%len(prompts)]
		path, body := build(*format, prompt)
		start := time.Now()
		resp, err := client.Post(*base+path, "application/json", bytes.NewReader(body))
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
	b, _ := json.Marshal(req)
	return path, b
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
