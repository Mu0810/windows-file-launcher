package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	for _, arg := range os.Args[1:] {
		if path, ok := strings.CutPrefix(arg, "/LOG="); ok {
			err := os.WriteFile(path, []byte("Installer log capture test passed\n"), 0600)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(2)
			}
		}
	}
	fmt.Println("Windows File Launcher: Windows executable ran successfully")
}
