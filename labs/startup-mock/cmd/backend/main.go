package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/bootstrap/config", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintln(w, `{"featureEnabled":true}`)
	})
	log.Fatal(http.ListenAndServe("127.0.0.1:18090", mux))
}
