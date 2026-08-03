package main

import (
	"os"

	"github.com/ggfarmco/diffview.nvim/nrev/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args[1:], os.Stdout, os.Stderr))
}
