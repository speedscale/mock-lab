// Prints the current UTC time in RFC3339Nano for replay window bookkeeping.
package main

import (
	"fmt"
	"time"
)

func main() {
	fmt.Println(time.Now().UTC().Format(time.RFC3339Nano))
}
