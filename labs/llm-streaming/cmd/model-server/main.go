// model-server is a stand-in for an LLM inference server. It streams a canned
// answer one token at a time in four wire formats so a proxymock replay can
// measure time to first token (TTFT) and inter-token latency (ITL) against it.
//
// Timing is set by environment variables, so the same recording can be
// replayed against a fast server and a slow one:
//
//	FIRST_TOKEN_MS  delay before the first output token (default 300)
//	TOKEN_GAP_MS    delay between output tokens (default 20)
//	TOKENS          output tokens per answer (default 20)
//	TOKENS_PER_FRAME output tokens sent in each frame (default 1)
//	PORT            listen port (default 8000)
package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type timing struct {
	firstToken time.Duration
	gap        time.Duration
	tokens     int
	perFrame   int
}

func main() {
	t := timing{
		firstToken: time.Duration(envInt("FIRST_TOKEN_MS", 300)) * time.Millisecond,
		gap:        time.Duration(envInt("TOKEN_GAP_MS", 20)) * time.Millisecond,
		tokens:     envInt("TOKENS", 20),
		perFrame:   max(1, envInt("TOKENS_PER_FRAME", 1)),
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("POST /v1/chat/completions", t.openAI)
	mux.HandleFunc("POST /v1/messages", t.anthropic)
	mux.HandleFunc("POST /api/chat", t.ollama)
	mux.HandleFunc("POST /model/{model}/converse-stream", t.bedrock)

	log.Printf("model-server on :%s first token %v, %d tokens %v apart, %d per frame",
		port, t.firstToken, t.tokens, t.gap, t.perFrame)
	log.Fatal(http.ListenAndServe(":"+port, mux))
}

func envInt(name string, def int) int {
	v, err := strconv.Atoi(os.Getenv(name))
	if err != nil || v < 0 {
		return def
	}
	return v
}

// request holds the fields the four formats share closely enough to read
// with one struct: the model name and whether the caller asked for usage.
type request struct {
	Model         string `json:"model"`
	StreamOptions struct {
		IncludeUsage bool `json:"include_usage"`
	} `json:"stream_options"`
}

func readRequest(r *http.Request) request {
	var req request
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Model == "" {
		req.Model = r.PathValue("model")
	}
	if req.Model == "" {
		req.Model = "lab-model"
	}
	return req
}

var answer = strings.Fields(`Replaying recorded prompts measures the latency your users
would see, because the request mix, the prompt lengths and the system prompts are
the ones production served, not a synthetic benchmark of fixed length.`)

// token returns the text of output frame i, which carries perFrame tokens.
func (t timing) token(i int) string {
	var b strings.Builder
	for j := i * t.perFrame; j < min((i+1)*t.perFrame, t.tokens); j++ {
		if j > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(answer[j%len(answer)])
	}
	return b.String()
}

func (t timing) frames() int {
	return (t.tokens + t.perFrame - 1) / t.perFrame
}

// stream sends start, then one output frame per call to emit after the
// configured delays, then end. Each write is flushed so frames leave the
// server at the moment they are produced.
func (t timing) stream(w http.ResponseWriter, contentType string, start func(), emit func(i int), end func()) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	flush := func() {
		if flusher != nil {
			flusher.Flush()
		}
	}
	start()
	flush()
	time.Sleep(t.firstToken)
	for i := 0; i < t.frames(); i++ {
		if i > 0 {
			time.Sleep(t.gap)
		}
		emit(i)
		flush()
	}
	end()
	flush()
}

func writeJSON(buf *bytes.Buffer, v any) {
	b, _ := json.Marshal(v)
	buf.Write(b)
}

// openAI streams an OpenAI-compatible chat completion: a role-only chunk,
// content chunks, a finish chunk, a usage chunk when the request set
// stream_options.include_usage, and the [DONE] sentinel.
func (t timing) openAI(w http.ResponseWriter, r *http.Request) {
	req := readRequest(r)
	id := fmt.Sprintf("chatcmpl-lab-%d", time.Now().UnixNano())
	created := time.Now().Unix()
	chunk := func(delta map[string]any, finish any) {
		var b bytes.Buffer
		b.WriteString("data: ")
		writeJSON(&b, map[string]any{
			"id": id, "object": "chat.completion.chunk", "created": created, "model": req.Model,
			"choices": []any{map[string]any{"index": 0, "delta": delta, "finish_reason": finish}},
		})
		b.WriteString("\n\n")
		_, _ = w.Write(b.Bytes())
	}
	t.stream(w, "text/event-stream",
		func() { chunk(map[string]any{"role": "assistant", "content": ""}, nil) },
		func(i int) { chunk(map[string]any{"content": t.token(i)}, nil) },
		func() {
			chunk(map[string]any{}, "stop")
			if req.StreamOptions.IncludeUsage {
				var b bytes.Buffer
				b.WriteString("data: ")
				writeJSON(&b, map[string]any{
					"id": id, "object": "chat.completion.chunk", "created": created, "model": req.Model,
					"choices": []any{},
					"usage":   map[string]int{"prompt_tokens": 42, "completion_tokens": t.tokens, "total_tokens": 42 + t.tokens},
				})
				b.WriteString("\n\n")
				_, _ = w.Write(b.Bytes())
			}
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
		})
}

// anthropic streams an Anthropic Messages response, ending with message_stop.
func (t timing) anthropic(w http.ResponseWriter, r *http.Request) {
	req := readRequest(r)
	event := func(name string, v any) {
		var b bytes.Buffer
		fmt.Fprintf(&b, "event: %s\ndata: ", name)
		writeJSON(&b, v)
		b.WriteString("\n\n")
		_, _ = w.Write(b.Bytes())
	}
	t.stream(w, "text/event-stream",
		func() {
			event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
				"id": fmt.Sprintf("msg_lab_%d", time.Now().UnixNano()), "type": "message", "role": "assistant",
				"model": req.Model, "content": []any{}, "usage": map[string]int{"input_tokens": 42, "output_tokens": 1},
			}})
			event("content_block_start", map[string]any{"type": "content_block_start", "index": 0,
				"content_block": map[string]any{"type": "text", "text": ""}})
		},
		func(i int) {
			event("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0,
				"delta": map[string]any{"type": "text_delta", "text": t.token(i)}})
		},
		func() {
			event("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
			event("message_delta", map[string]any{"type": "message_delta",
				"delta": map[string]any{"stop_reason": "end_turn"}, "usage": map[string]int{"output_tokens": t.tokens}})
			event("message_stop", map[string]any{"type": "message_stop"})
		})
}

// ollama streams Ollama's native /api/chat NDJSON, ending with done: true.
func (t timing) ollama(w http.ResponseWriter, r *http.Request) {
	req := readRequest(r)
	line := func(v any) {
		var b bytes.Buffer
		writeJSON(&b, v)
		b.WriteByte('\n')
		_, _ = w.Write(b.Bytes())
	}
	now := func() string { return time.Now().UTC().Format(time.RFC3339Nano) }
	t.stream(w, "application/x-ndjson",
		func() {},
		func(i int) {
			line(map[string]any{"model": req.Model, "created_at": now(),
				"message": map[string]any{"role": "assistant", "content": t.token(i)}, "done": false})
		},
		func() {
			line(map[string]any{"model": req.Model, "created_at": now(),
				"message": map[string]any{"role": "assistant", "content": ""}, "done": true,
				"done_reason": "stop", "prompt_eval_count": 42, "eval_count": t.tokens})
		})
}

// bedrock streams an Amazon Bedrock ConverseStream response in the AWS event
// stream binary framing, ending with messageStop and a metadata usage event.
func (t timing) bedrock(w http.ResponseWriter, r *http.Request) {
	_ = readRequest(r)
	event := func(name string, v any) {
		payload, _ := json.Marshal(v)
		_, _ = w.Write(eventStreamMessage(name, payload))
	}
	t.stream(w, "application/vnd.amazon.eventstream",
		func() { event("messageStart", map[string]any{"role": "assistant"}) },
		func(i int) {
			event("contentBlockDelta", map[string]any{"contentBlockIndex": 0,
				"delta": map[string]any{"text": t.token(i)}})
		},
		func() {
			event("contentBlockStop", map[string]any{"contentBlockIndex": 0})
			event("messageStop", map[string]any{"stopReason": "end_turn"})
			event("metadata", map[string]any{
				"usage":   map[string]int{"inputTokens": 42, "outputTokens": t.tokens, "totalTokens": 42 + t.tokens},
				"metrics": map[string]int{"latencyMs": int((t.firstToken + time.Duration(t.tokens)*t.gap).Milliseconds())},
			})
		})
}

// eventStreamMessage encodes one AWS event stream message: a prelude with the
// total and header lengths and its CRC, string headers, the payload, and a
// CRC of everything before it.
func eventStreamMessage(eventType string, payload []byte) []byte {
	var headers bytes.Buffer
	for _, h := range [][2]string{
		{":event-type", eventType},
		{":content-type", "application/json"},
		{":message-type", "event"},
	} {
		headers.WriteByte(byte(len(h[0])))
		headers.WriteString(h[0])
		headers.WriteByte(7) // string value type
		_ = binary.Write(&headers, binary.BigEndian, uint16(len(h[1])))
		headers.WriteString(h[1])
	}
	total := 12 + headers.Len() + len(payload) + 4
	var msg bytes.Buffer
	_ = binary.Write(&msg, binary.BigEndian, uint32(total))
	_ = binary.Write(&msg, binary.BigEndian, uint32(headers.Len()))
	_ = binary.Write(&msg, binary.BigEndian, crc32.ChecksumIEEE(msg.Bytes()))
	msg.Write(headers.Bytes())
	msg.Write(payload)
	_ = binary.Write(&msg, binary.BigEndian, crc32.ChecksumIEEE(msg.Bytes()))
	return msg.Bytes()
}
