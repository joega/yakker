package tool

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/joega/yakker/internal/radio"
)

func TestInstallIncludesBundledStationArtwork(t *testing.T) {
	stations, err := radio.LoadStations("../../stations.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, station := range stations {
		artwork, _ := station["artwork"].(string)
		if !slices.Contains(installFiles, artwork) {
			t.Errorf("station %s artwork %q missing from installation", station["id"], artwork)
		}
	}
}

func installFixture(t *testing.T) (string, string) {
	t.Helper()
	base := t.TempDir()
	source := filepath.Join(base, "source")
	target := filepath.Join(base, "omarchy", "plugins", "io.github.joega.yakker")
	for _, name := range installFiles {
		path := filepath.Join(source, name)
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		mode := os.FileMode(0644)
		if name == "yakker-controller" {
			mode = 0755
		}
		if err := os.WriteFile(path, []byte("original "+name), mode); err != nil {
			t.Fatal(err)
		}
	}
	return source, target
}
func noValidation(string) error { return nil }
func TestInstallStagesExecutableAndPreservesPrevious(t *testing.T) {
	source, target := installFixture(t)
	if backup, err := stageInstall(source, target, noValidation); err != nil || backup != "" {
		t.Fatalf("first install: %s %v", backup, err)
	}
	if err := validateOwned(target, source); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(target, "yakker-controller"))
	if err != nil || info.Mode().Perm()&0111 == 0 {
		t.Fatal("lost executable permissions")
	}
	if err = os.WriteFile(filepath.Join(source, "yakker-controller"), []byte("new controller"), 0755); err != nil {
		t.Fatal(err)
	}
	backup, err := stageInstall(source, target, noValidation)
	if err != nil {
		t.Fatal(err)
	}
	old, err := os.ReadFile(filepath.Join(backup, "yakker-controller"))
	if err != nil || string(old) != "original yakker-controller" {
		t.Fatal("did not retain previous installation")
	}
	if filepath.Dir(backup) == filepath.Dir(target) {
		t.Fatal("backup would be discovered as a duplicate plugin")
	}
	if err = validateOwned(target, source); err != nil {
		t.Fatal(err)
	}
}
func TestInstallRefusesEditedOrUnmanagedFiles(t *testing.T) {
	for _, mode := range []string{"edited", "unmanaged", "other-source", "symlink"} {
		t.Run(mode, func(t *testing.T) {
			source, target := installFixture(t)
			if _, err := stageInstall(source, target, noValidation); err != nil {
				t.Fatal(err)
			}
			switch mode {
			case "edited":
				if err := os.WriteFile(filepath.Join(target, "Panel.qml"), []byte("user edit"), 0644); err != nil {
					t.Fatal(err)
				}
			case "unmanaged":
				if err := os.Remove(filepath.Join(target, ".local-source.json")); err != nil {
					t.Fatal(err)
				}
			case "other-source":
				source = filepath.Dir(source)
			case "symlink":
				old := target + "-real"
				if err := os.Rename(target, old); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(old, target); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := stageInstall(source, target, noValidation); err == nil {
				t.Fatal("overwrote protected installation")
			}
		})
	}
}
func TestFailedStagingLeavesInstalledCopy(t *testing.T) {
	source, target := installFixture(t)
	if _, err := stageInstall(source, target, noValidation); err != nil {
		t.Fatal(err)
	}
	original, err := digest(filepath.Join(target, "yakker-controller"))
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(source, "yakker-controller"), []byte("updated"), 0755); err != nil {
		t.Fatal(err)
	}
	if _, err = stageInstall(source, target, func(string) error { return errors.New("validation failed") }); err == nil {
		t.Fatal("ignored validation failure")
	}
	actual, err := digest(filepath.Join(target, "yakker-controller"))
	if err != nil || actual != original {
		t.Fatal("failed staging modified installed copy")
	}
}
func TestMissingBuildLeavesInstalledCopy(t *testing.T) {
	source, target := installFixture(t)
	if _, err := stageInstall(source, target, noValidation); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(source, "yakker-controller")); err != nil {
		t.Fatal(err)
	}
	if _, err := stageInstall(source, target, noValidation); err == nil {
		t.Fatal("installed without controller")
	}
	if err := validateOwned(target, source); err != nil {
		t.Fatal(err)
	}
}
