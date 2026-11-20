// Yakker Controller is the shell-owned mpv controller. Its only protocol is JSON lines.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"github.com/joega/yakker/internal/radio"
)

func main() {
	// Linux parent-death signals belong to the spawning OS thread. Keep that
	// thread alive for the entire helper/player lifecycle.
	runtime.LockOSThread()
	syscall.Umask(0077)
	err := radio.ParentGuard()
	if err == nil {
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
		defer cancel()
		err = radio.Run(ctx, radio.Config{}, os.Stdin, os.Stdout, os.Stderr)
	}
	if err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"state": "error", "wanted": false, "error": err.Error()})
		fmt.Fprintln(os.Stderr, "yakker-controller:", err)
		os.Exit(1)
	}
}
