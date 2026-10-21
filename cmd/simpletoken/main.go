// simpletoken is SimpleToken's binary: the menu bar app (mygo native UI) that tracks AI coding usage and limits.
package main

import (
	"log"

	"github.com/HanlunWang/SimpleToken/gui"
)

func main() {
	if err := gui.Run(); err != nil {
		log.Fatal(err)
	}
}
