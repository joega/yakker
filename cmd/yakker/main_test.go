package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCommandHelpAndArgumentErrors(t *testing.T) {
	for _, tc := range []struct {
		name     string
		args     []string
		code     int
		contains string
	}{
		{"help", []string{"--help"}, 0, "listen [options]"},
		{"tui-help", []string{"tui", "--help"}, 0, "enter tune"},
		{"tui-needs-terminal", []string{"tui"}, 1, "interactive terminal"},
		{"listen-help", []string{"listen", "--help"}, 0, "Each command is followed by Enter"},
		{"missing", nil, 2, "Usage:"},
		{"invalid-volume", []string{"listen", "--volume", "101"}, 1, "volume must be an integer"},
		{"unknown", []string{"bogus"}, 1, "unknown command"},
		{"extra-install", []string{"install", "unexpected"}, 2, "unexpected arguments"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var output, logs bytes.Buffer
			code := run(context.Background(), tc.args, strings.NewReader(""), &output, &logs)
			if code != tc.code || !strings.Contains(output.String()+logs.String(), tc.contains) {
				t.Fatalf("exit=%d output=%s logs=%s", code, &output, &logs)
			}
		})
	}
}

func TestProjectRootDoesNotFollowForeignWorkingDirectory(t *testing.T) {
	binary, working := t.TempDir(), t.TempDir()
	writeManifest := func(root, id string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, "manifest.json"), []byte(`{"id":"`+id+`"}`), 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeManifest(binary, "io.github.joega.yakker")
	writeManifest(working, "another.plugin")
	if got := findProjectRoot(binary, working); got != binary {
		t.Fatal("foreign project redirected bundle", got)
	}
	if err := os.Remove(filepath.Join(binary, "manifest.json")); err != nil {
		t.Fatal(err)
	}
	writeManifest(working, "io.github.joega.yakker")
	if got := findProjectRoot(binary, working); got != working {
		t.Fatal("go run source fallback failed", got)
	}
	writeManifest(working, "another.plugin")
	if got := findProjectRoot(binary, working); got != binary {
		t.Fatal("foreign project became standalone root", got)
	}
}
