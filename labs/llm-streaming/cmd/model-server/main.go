// model-server is a stand-in for an LLM inference server. It streams answers
// one token at a time in four wire formats so a proxymock replay can measure
// time to first token (TTFT) and inter-token latency (ITL) against it, and
// score its answers against recorded ones.
//
// Timing is set by environment variables, so the same recording can be
// replayed against a fast server and a slow one:
//
//	FIRST_TOKEN_MS  delay before the first output token (default 300)
//	TOKEN_GAP_MS    delay between output tokens (default 20)
//	TOKENS          output tokens per canned answer (default 20)
//	TOKENS_PER_FRAME output tokens sent in each frame (default 1)
//	PORT            listen port (default 8000)
//
// What it answers depends on the request. A request with no tool definitions
// gets the same canned answer, TOKENS tokens long. A request that carries tool
// definitions is answered as a support assistant would answer it: a question
// about an order becomes a get_order tool call, and any other question gets a
// written answer. These variables make the server a different model:
//
//	MODE        "regressed" calls get_order with the wrong order for one
//	            prompt and rewords one written answer (default "normal")
//	MODEL_NAME  when set, a request that names another model gets a 404
//	API_KEY     when set, a request without this key gets a 401
//
// MODEL_NAME and API_KEY do not apply to the Bedrock endpoint.
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
	"regexp"
	"strconv"
	"strings"
	"time"
)

type server struct {
	firstToken time.Duration
	gap        time.Duration
	tokens     int
	perFrame   int
	regressed  bool
	model      string
	apiKey     string
}

func main() {
	s := server{
		firstToken: time.Duration(envInt("FIRST_TOKEN_MS", 300)) * time.Millisecond,
		gap:        time.Duration(envInt("TOKEN_GAP_MS", 20)) * time.Millisecond,
		tokens:     envInt("TOKENS", 20),
		perFrame:   max(1, envInt("TOKENS_PER_FRAME", 1)),
		regressed:  os.Getenv("MODE") == "regressed",
		model:      os.Getenv("MODEL_NAME"),
		apiKey:     os.Getenv("API_KEY"),
	}
	port := os.Getenv("PORT")
	if port == "" {
		port = "8000"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("POST /v1/chat/completions", s.serve(s.openAI, true))
	mux.HandleFunc("POST /v1/messages", s.serve(s.anthropic, true))
	mux.HandleFunc("POST /api/chat", s.serve(s.ollama, true))
	// Bedrock names the model in the URL and signs the request instead of
	// sending a key. This server checks no signatures, so MODEL_NAME and
	// API_KEY do not apply to it.
	mux.HandleFunc("POST /model/{model}/converse-stream", s.serve(s.bedrock, false))

	mode := "normal"
	if s.regressed {
		mode = "regressed"
	}
	log.Printf("model-server on :%s %s mode, first token %v, %d tokens %v apart, %d per frame",
		port, mode, s.firstToken, s.tokens, s.gap, s.perFrame)
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
// with one struct.
type request struct {
	Model         string `json:"model"`
	StreamOptions struct {
		IncludeUsage bool `json:"include_usage"`
	} `json:"stream_options"`
	Messages []struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"messages"`
	// Tool definitions: "tools" in the OpenAI, Anthropic and Ollama formats,
	// "toolConfig.tools" in Bedrock Converse.
	Tools      []json.RawMessage `json:"tools"`
	ToolConfig struct {
		Tools []json.RawMessage `json:"tools"`
	} `json:"toolConfig"`
}

func (r request) hasTools() bool {
	return len(r.Tools) > 0 || len(r.ToolConfig.Tools) > 0
}

// prompt returns the text of the last user message. Content is a string in
// most formats and a list of blocks in Bedrock Converse.
func (r request) prompt() string {
	for i := len(r.Messages) - 1; i >= 0; i-- {
		if r.Messages[i].Role != "user" {
			continue
		}
		var text string
		if json.Unmarshal(r.Messages[i].Content, &text) == nil {
			return text
		}
		var blocks []struct {
			Text string `json:"text"`
		}
		_ = json.Unmarshal(r.Messages[i].Content, &blocks)
		for _, b := range blocks {
			text += b.Text
		}
		return text
	}
	return ""
}

// serve reads the request and hands it to one format's handler. With checked
// set it first turns away the requests this model would not accept.
func (s server) serve(format func(http.ResponseWriter, request, reply), checked bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req request
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req.Model == "" {
			req.Model = r.PathValue("model")
		}
		if req.Model == "" {
			req.Model = "lab-model"
		}
		if checked && s.apiKey != "" && !sentKey(r, s.apiKey) {
			refuse(w, http.StatusUnauthorized, "invalid API key")
			return
		}
		if checked && s.model != "" && req.Model != s.model {
			refuse(w, http.StatusNotFound, fmt.Sprintf("the model %q does not exist", req.Model))
			return
		}
		format(w, req, s.answer(req))
	}
}

func sentKey(r *http.Request, key string) bool {
	return r.Header.Get("Authorization") == "Bearer "+key || r.Header.Get("x-api-key") == key
}

func refuse(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"message": message}})
}

// reply is what the model says to one request: a written answer, or a call
// to one tool.
type reply struct {
	// tool is the name of the tool called, empty for a written answer.
	tool string
	// frames are the pieces of the answer in the order they are sent. Joined,
	// they are the answer's text or the tool call's JSON arguments.
	frames []string
	tokens int
}

var canned = strings.Fields(`Replaying recorded prompts measures the latency your users
would see, because the request mix, the prompt lengths and the system prompts are
the ones production served, not a synthetic benchmark of fixed length.`)

// written holds the answer to each kind of question. The regressed model
// rewords one of them: the facts are the same, the sentences are not.
var written = []struct {
	about, answer, regressed string
}{
	{about: "return policy",
		answer:    "Opened electronics can be returned within 30 days of delivery for a full refund, as long as the original packaging and accessories are included.",
		regressed: "Opened electronics may be returned for a full refund within 30 days of delivery. The original packaging and accessories must be included."},
	{about: "priority support",
		answer: "Priority support is included in the Business and Enterprise plans, with a first response within one hour."},
	{about: "refund take",
		answer: "A refund appears on the original payment method within five business days of the return being received."},
	{about: "translate to spanish",
		answer: "Su reembolso fue emitido y debería aparecer en un plazo de cinco días hábiles."},
	{about: "summarize this ticket",
		answer: "Checkout fails with a 502 about half the time after a gift card is applied, starting with Tuesday's release."},
}

const fallback = "I can help with orders, returns, refunds and plans. Which of those is this about?"

var orderNumber = regexp.MustCompile(`(?i)\border (\d+)`)

// misread is the order number the regressed model gets wrong, and what it
// asks for instead: two digits swapped.
var misread = map[string]string{"77120": "77210"}

func (s server) answer(req request) reply {
	if !req.hasTools() {
		return s.text(cycle(canned, s.tokens))
	}
	prompt := req.prompt()
	if m := orderNumber.FindStringSubmatch(prompt); m != nil {
		order := m[1]
		if s.regressed && misread[order] != "" {
			order = misread[order]
		}
		// Sent in pieces, as a model streams the arguments of a call.
		return reply{tool: "get_order", frames: []string{`{"order_id"`, `:`, order + `}`}, tokens: 3}
	}
	for _, w := range written {
		if !strings.Contains(strings.ToLower(prompt), w.about) {
			continue
		}
		if s.regressed && w.regressed != "" {
			return s.text(strings.Fields(w.regressed))
		}
		return s.text(strings.Fields(w.answer))
	}
	return s.text(strings.Fields(fallback))
}

func cycle(words []string, n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = words[i%len(words)]
	}
	return out
}

// text splits an answer into frames of perFrame tokens.
func (s server) text(words []string) reply {
	r := reply{tokens: len(words)}
	for i := 0; i < len(words); i += s.perFrame {
		frame := strings.Join(words[i:min(i+s.perFrame, len(words))], " ")
		if i > 0 {
			frame = " " + frame
		}
		r.frames = append(r.frames, frame)
	}
	return r
}

// stream sends start, then one output frame per call to emit after the
// configured delays, then end. Each write is flushed so frames leave the
// server at the moment they are produced.
func (s server) stream(w http.ResponseWriter, contentType string, frames int, start func(), emit func(i int), end func()) {
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
	time.Sleep(s.firstToken)
	for i := 0; i < frames; i++ {
		if i > 0 {
			time.Sleep(s.gap)
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

func callID() string { return fmt.Sprintf("call_lab_%d", time.Now().UnixNano()) }

// openAI streams an OpenAI-compatible chat completion: a role-only chunk,
// content or tool-call chunks, a finish chunk, a usage chunk when the request
// set stream_options.include_usage, and the [DONE] sentinel.
func (s server) openAI(w http.ResponseWriter, req request, out reply) {
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
	first := map[string]any{"role": "assistant", "content": ""}
	piece := func(i int) map[string]any { return map[string]any{"content": out.frames[i]} }
	finish := "stop"
	if out.tool != "" {
		first = map[string]any{"role": "assistant", "content": nil, "tool_calls": []any{map[string]any{
			"index": 0, "id": callID(), "type": "function",
			"function": map[string]string{"name": out.tool, "arguments": ""},
		}}}
		piece = func(i int) map[string]any {
			return map[string]any{"tool_calls": []any{map[string]any{
				"index": 0, "function": map[string]string{"arguments": out.frames[i]},
			}}}
		}
		finish = "tool_calls"
	}
	s.stream(w, "text/event-stream", len(out.frames),
		func() { chunk(first, nil) },
		func(i int) { chunk(piece(i), nil) },
		func() {
			chunk(map[string]any{}, finish)
			if req.StreamOptions.IncludeUsage {
				var b bytes.Buffer
				b.WriteString("data: ")
				writeJSON(&b, map[string]any{
					"id": id, "object": "chat.completion.chunk", "created": created, "model": req.Model,
					"choices": []any{},
					"usage":   map[string]int{"prompt_tokens": 42, "completion_tokens": out.tokens, "total_tokens": 42 + out.tokens},
				})
				b.WriteString("\n\n")
				_, _ = w.Write(b.Bytes())
			}
			_, _ = w.Write([]byte("data: [DONE]\n\n"))
		})
}

// anthropic streams an Anthropic Messages response, ending with message_stop.
func (s server) anthropic(w http.ResponseWriter, req request, out reply) {
	event := func(name string, v any) {
		var b bytes.Buffer
		fmt.Fprintf(&b, "event: %s\ndata: ", name)
		writeJSON(&b, v)
		b.WriteString("\n\n")
		_, _ = w.Write(b.Bytes())
	}
	block := map[string]any{"type": "text", "text": ""}
	delta := func(i int) map[string]any { return map[string]any{"type": "text_delta", "text": out.frames[i]} }
	stop := "end_turn"
	if out.tool != "" {
		block = map[string]any{"type": "tool_use", "id": "toolu_" + callID(), "name": out.tool, "input": map[string]any{}}
		delta = func(i int) map[string]any {
			return map[string]any{"type": "input_json_delta", "partial_json": out.frames[i]}
		}
		stop = "tool_use"
	}
	s.stream(w, "text/event-stream", len(out.frames),
		func() {
			event("message_start", map[string]any{"type": "message_start", "message": map[string]any{
				"id": fmt.Sprintf("msg_lab_%d", time.Now().UnixNano()), "type": "message", "role": "assistant",
				"model": req.Model, "content": []any{}, "usage": map[string]int{"input_tokens": 42, "output_tokens": 1},
			}})
			event("content_block_start", map[string]any{"type": "content_block_start", "index": 0, "content_block": block})
		},
		func(i int) {
			event("content_block_delta", map[string]any{"type": "content_block_delta", "index": 0, "delta": delta(i)})
		},
		func() {
			event("content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
			event("message_delta", map[string]any{"type": "message_delta",
				"delta": map[string]any{"stop_reason": stop}, "usage": map[string]int{"output_tokens": out.tokens}})
			event("message_stop", map[string]any{"type": "message_stop"})
		})
}

// ollama streams Ollama's native /api/chat NDJSON, ending with done: true.
// Ollama sends a tool call whole, in one line, with its arguments as an
// object.
func (s server) ollama(w http.ResponseWriter, req request, out reply) {
	line := func(v any) {
		var b bytes.Buffer
		writeJSON(&b, v)
		b.WriteByte('\n')
		_, _ = w.Write(b.Bytes())
	}
	now := func() string { return time.Now().UTC().Format(time.RFC3339Nano) }
	message := func(m map[string]any) {
		m["role"] = "assistant"
		line(map[string]any{"model": req.Model, "created_at": now(), "message": m, "done": false})
	}
	frames := len(out.frames)
	emit := func(i int) { message(map[string]any{"content": out.frames[i]}) }
	if out.tool != "" {
		frames = 1
		emit = func(int) {
			message(map[string]any{"content": "", "tool_calls": []any{map[string]any{
				"function": map[string]any{"name": out.tool, "arguments": json.RawMessage(strings.Join(out.frames, ""))},
			}}})
		}
	}
	s.stream(w, "application/x-ndjson", frames,
		func() {},
		emit,
		func() {
			line(map[string]any{"model": req.Model, "created_at": now(),
				"message": map[string]any{"role": "assistant", "content": ""}, "done": true,
				"done_reason": "stop", "prompt_eval_count": 42, "eval_count": out.tokens})
		})
}

// bedrock streams an Amazon Bedrock ConverseStream response in the AWS event
// stream binary framing, ending with messageStop and a metadata usage event.
func (s server) bedrock(w http.ResponseWriter, _ request, out reply) {
	event := func(name string, v any) {
		payload, _ := json.Marshal(v)
		_, _ = w.Write(eventStreamMessage(name, payload))
	}
	delta := func(i int) map[string]any { return map[string]any{"text": out.frames[i]} }
	stop := "end_turn"
	if out.tool != "" {
		delta = func(i int) map[string]any {
			return map[string]any{"toolUse": map[string]string{"input": out.frames[i]}}
		}
		stop = "tool_use"
	}
	s.stream(w, "application/vnd.amazon.eventstream", len(out.frames),
		func() {
			event("messageStart", map[string]any{"role": "assistant"})
			if out.tool != "" {
				event("contentBlockStart", map[string]any{"contentBlockIndex": 0, "start": map[string]any{
					"toolUse": map[string]string{"toolUseId": "tooluse_" + callID(), "name": out.tool},
				}})
			}
		},
		func(i int) {
			event("contentBlockDelta", map[string]any{"contentBlockIndex": 0, "delta": delta(i)})
		},
		func() {
			event("contentBlockStop", map[string]any{"contentBlockIndex": 0})
			event("messageStop", map[string]any{"stopReason": stop})
			event("metadata", map[string]any{
				"usage":   map[string]int{"inputTokens": 42, "outputTokens": out.tokens, "totalTokens": 42 + out.tokens},
				"metrics": map[string]int{"latencyMs": int((s.firstToken + time.Duration(out.tokens)*s.gap).Milliseconds())},
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
