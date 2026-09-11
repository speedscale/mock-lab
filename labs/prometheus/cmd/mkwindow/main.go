// Converts a replay's exact UTC boundaries into the window file agents parse.
// The floor and ceiling produce a conservative whole-second query interval so
// every Prometheus query uses the file values unchanged.
package main

import (
	"fmt"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: mkwindow <start-rfc3339nano> <end-rfc3339nano>")
		os.Exit(2)
	}
	start, err := time.Parse(time.RFC3339Nano, os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse start: %v\n", err)
		os.Exit(2)
	}
	end, err := time.Parse(time.RFC3339Nano, os.Args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse end: %v\n", err)
		os.Exit(2)
	}
	if !end.After(start) {
		fmt.Fprintln(os.Stderr, "end must be after start")
		os.Exit(2)
	}

	queryStart := start.UTC().Truncate(time.Second)
	// One extra second past the ceiling leaves room for the final 1-second
	// Prometheus scrape of the interval.
	queryEnd := end.UTC().Truncate(time.Second).Add(2 * time.Second)

	fmt.Printf(
		"{\n  \"start\": %q,\n  \"end\": %q,\n  \"query_start\": %q,\n  \"query_end\": %q,\n  \"window_seconds\": %d\n}\n",
		start.UTC().Format(time.RFC3339Nano),
		end.UTC().Format(time.RFC3339Nano),
		queryStart.Format(time.RFC3339),
		queryEnd.Format(time.RFC3339),
		int64(queryEnd.Sub(queryStart)/time.Second),
	)
}
