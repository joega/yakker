// Yakker provides standalone radio playback and local widget installation.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/joega/yakker/internal/radio"
	"github.com/joega/yakker/internal/tool"
)

const usage = `Usage: yakker <command>

  tui [options]     Open the interactive radio player
  listen [options]  Listen independently of the Omarchy widget
  install           Install the built widget locally

Try: yakker tui --volume 60
     yakker listen --list-stations
     yakker listen --station ID --volume 60
     yakker listen --help
`

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer cancel()
	os.Exit(run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(ctx context.Context, args []string, input io.Reader, output, logs io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(logs, usage)
		return 2
	}
	if args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		fmt.Fprint(output, usage)
		return 0
	}
	if args[0] != "listen" && args[0] != "tui" && len(args) != 1 {
		fmt.Fprintln(logs, "yakker: unexpected arguments")
		return 2
	}
	root, err := projectRoot()
	if err == nil {
		switch args[0] {
		case "tui":
			err = tool.TUI(ctx, root, args[1:], input, output, logs)
		case "listen":
			err = tool.Listen(ctx, root, args[1:], input, output, logs)
		case "install":
			err = tool.Install(root)
		default:
			err = fmt.Errorf("unknown command %q; try yakker --help", args[0])
		}
	}
	if err != nil {
		fmt.Fprintln(logs, "yakker:", err)
		return 1
	}
	return 0
}

func projectRoot() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	working, _ := os.Getwd()
	return findProjectRoot(filepath.Dir(executable), working), nil
}

// Prefer the binary's own bundle. A foreign manifest in the caller's working
// directory must not redirect playback or installation to another project.
// The cwd fallback supports go run, whose executable lives in Go's cache.
func findProjectRoot(executableDir, workingDir string) string {
	isRadio := func(root string) bool {
		if root == "" {
			return false
		}
		data, err := os.ReadFile(filepath.Join(root, "manifest.json"))
		if err != nil {
			return false
		}
		var manifest struct {
			ID string `json:"id"`
		}
		return json.Unmarshal(data, &manifest) == nil && manifest.ID == radio.PluginID
	}
	if isRadio(executableDir) {
		return executableDir
	}
	if isRadio(workingDir) {
		return workingDir
	}
	return executableDir // Standalone --help and --url need no bundle manifest.
}
