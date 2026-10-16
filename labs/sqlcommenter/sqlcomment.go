package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
)

// traceContext is the W3C trace context of the request being served.
type traceContext struct {
	TraceID string // 32 lower-case hex
	SpanID  string // 16 lower-case hex, this service's span for the request
	Flags   string // 2 hex
	Started bool   // true when no valid traceparent arrived and this service started the trace
}

// Traceparent renders the context as a W3C traceparent value.
func (t traceContext) Traceparent() string {
	return "00-" + t.TraceID + "-" + t.SpanID + "-" + t.Flags
}

var traceparentRe = regexp.MustCompile(`^00-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$`)

// traceFromRequest continues the trace of the inbound traceparent header, or starts a new trace when there is none or
// it is malformed. Either way the request gets a new span id of its own, as an OpenTelemetry server span would.
func traceFromRequest(r *http.Request) traceContext {
	m := traceparentRe.FindStringSubmatch(strings.ToLower(strings.TrimSpace(r.Header.Get("traceparent"))))
	if m != nil && strings.Trim(m[1], "0") != "" && strings.Trim(m[2], "0") != "" {
		return traceContext{TraceID: m[1], SpanID: randomHex(8), Flags: m[3]}
	}
	return traceContext{TraceID: randomHex(16), SpanID: randomHex(8), Flags: "01", Started: true}
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

type requestTagsKey struct{}

// requestTags is what each SQL statement a request runs is tagged with.
type requestTags struct {
	Trace traceContext
	Route string // the route template, such as /orders/{id}
}

func withRequestTags(ctx context.Context, tags requestTags) context.Context {
	return context.WithValue(ctx, requestTagsKey{}, tags)
}

func tagsFrom(ctx context.Context) (requestTags, bool) {
	tags, ok := ctx.Value(requestTagsKey{}).(requestTags)
	return tags, ok
}

// sqlComment renders tags in the sqlcommenter format (https://google.github.io/sqlcommenter/spec/): keys sorted,
// each value URL-encoded and wrapped in single quotes, pairs joined by commas, all inside one /* */ comment.
func sqlComment(tags map[string]string) string {
	if len(tags) == 0 {
		return ""
	}
	keys := make([]string, 0, len(tags))
	for k := range tags {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, encodeCommentPart(k)+"='"+encodeCommentPart(tags[k])+"'")
	}
	return "/*" + strings.Join(parts, ",") + "*/"
}

// encodeCommentPart URL-encodes a key or value and escapes single quotes, as the sqlcommenter spec requires.
func encodeCommentPart(s string) string {
	return strings.ReplaceAll(url.PathEscape(s), "'", `\'`)
}

// commentMode is what the app writes into the SQL it runs, chosen at start-up with the SQL_COMMENTS variable, so one
// app can stand in for a service at each level of instrumentation.
type commentMode string

const (
	// commentTrace traces each request (continuing an inbound traceparent or starting a trace) and comments its SQL
	// with the route and the traceparent, as an OpenTelemetry sqlcommenter integration does. This is the default.
	commentTrace commentMode = "trace"
	// commentRoute traces nothing and comments SQL with the route only, as Rails query log tags do without tracing.
	commentRoute commentMode = "route"
	// commentOff traces nothing and leaves SQL uncommented, as an uninstrumented service does.
	commentOff commentMode = "off"
)

// sqlComments is the comment mode the app runs with; main sets it from SQL_COMMENTS.
var sqlComments = commentTrace

func parseCommentMode(s string) (commentMode, error) {
	switch m := commentMode(strings.ToLower(strings.TrimSpace(s))); m {
	case "":
		return commentTrace, nil
	case commentTrace, commentRoute, commentOff:
		return m, nil
	}
	return "", fmt.Errorf("SQL_COMMENTS=%q: want trace, route or off", s)
}

// tag appends the sqlcommenter comment for the request in ctx to sql, as the comment mode allows. A statement run
// outside a request (start-up, the health check) is returned unchanged.
func tag(ctx context.Context, sql string) string {
	tags, ok := tagsFrom(ctx)
	if !ok || sqlComments == commentOff {
		return sql
	}
	comment := map[string]string{"db_driver": "pgx", "route": tags.Route}
	if sqlComments == commentTrace {
		comment["traceparent"] = tags.Trace.Traceparent()
	}
	return sql + " " + sqlComment(comment)
}
