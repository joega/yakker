package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/joega/yakker/internal/radio"
)

func TestReleaseIncludesBundledStationArtwork(t *testing.T) {
	stations, err := radio.LoadStations("../../stations.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, station := range stations {
		artwork, _ := station["artwork"].(string)
		if !slices.Contains(bundleFiles, artwork) {
			t.Errorf("station %s artwork %q missing from release", station["id"], artwork)
		}
	}
}

func TestArchiveIsDeterministicAndRetainsExecutableModes(t *testing.T) {
	files := map[string]entry{"yakker-controller": {[]byte("binary"), 0755}, "README.md": {[]byte("documentation"), 0644}, "assets/logo.png": {[]byte("image"), 0644}}
	var first, second bytes.Buffer
	if err := writeArchive(&first, files); err != nil {
		t.Fatal(err)
	}
	if err := writeArchive(&second, files); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Bytes(), second.Bytes()) {
		t.Fatal("archive changed without source changes")
	}
	zipped, err := gzip.NewReader(&first)
	if err != nil {
		t.Fatal(err)
	}
	defer zipped.Close()
	reader := tar.NewReader(zipped)
	seen := map[string]bool{}
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		seen[header.Name] = true
		if header.Uid != 0 || header.Gid != 0 || header.ModTime.Unix() != 0 {
			t.Fatal("archive leaked machine-specific ownership or time")
		}
		if header.Name == "yakker/yakker-controller" && header.Mode != 0755 {
			t.Fatal("controller is not executable")
		}
		if _, err = io.Copy(io.Discard, reader); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"yakker/yakker-controller", "yakker/README.md", "yakker/assets/logo.png"} {
		if !seen[name] {
			t.Fatal("missing", name)
		}
	}
}
func TestArchiveRejectsEscapingPaths(t *testing.T) {
	for _, name := range []string{"../escape", "/absolute", "a/../../escape", "a\\escape"} {
		if err := writeArchive(io.Discard, map[string]entry{name: {[]byte("x"), 0644}}); err == nil {
			t.Fatal("accepted", name)
		}
	}
}

func TestArchiveVersionMustMatchManifest(t *testing.T) {
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "manifest.json"), []byte(`{"version":"1.1.1"}`), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := release(context.Background(), source, t.TempDir(), "amd64", "9.9.9"); err == nil || !strings.Contains(err.Error(), "match manifest") {
		t.Fatal(err)
	}
}
