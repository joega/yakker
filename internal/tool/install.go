package tool

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/joega/yakker/internal/radio"
)

var installFiles = []string{
	"manifest.json", "qmldir", "BarWidget.qml",
	"Panel.qml", "RadioService.qml", "StationLogo.qml", "RecordingsView.qml",
	"assets/sports-hub.png", "assets/weei-fm.png", "assets/wscr.webp",
	"assets/wxyt-fm.webp", "assets/espn-new-york.png", "assets/wfan.webp",
	"assets/wip-fm.webp", "assets/kdka-fm.png", "assets/tsn-1050.png",
	"assets/wbns-fm.png", "assets/wkrk-fm.webp", "assets/kwfn-fm.webp",
	"assets/wzgc-fm.webp", "assets/kkfn-fm.webp", "assets/klac.png",
	"assets/krld-fm.webp", "assets/kfan.png",
	"assets/kiro-am.webp", "assets/sportsnet-590.png", "assets/tsn-690.png",
	"assets/talksport.png", "assets/talksport-2.png", "assets/bbc-radio-5-live.png",
	"assets/off-the-ball.png", "assets/README.md", "yakker-controller",
	"stations.json", "README.md", "LICENSE",
	"docs/yakker-popup.png", "docs/yakker-stations.png", "docs/yakker-dvr.png",
}

type installMarker struct {
	Source string            `json:"source"`
	Files  map[string]string `json:"files"`
}

func digest(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:]), nil
}
func command(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return strings.TrimSpace(string(output)), nil
}
func validateOwned(target, source string) error {
	info, err := os.Lstat(target)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to overwrite an unmanaged plugin: %s", target)
	}
	data, err := os.ReadFile(filepath.Join(target, ".local-source.json"))
	if err != nil {
		return fmt.Errorf("refusing to overwrite an unmanaged plugin: %s", target)
	}
	var marker installMarker
	if err = json.Unmarshal(data, &marker); err != nil {
		return err
	}
	if marker.Source != source || len(marker.Files) == 0 {
		return fmt.Errorf("installed plugin belongs to another source checkout or has no file manifest")
	}
	for name, want := range marker.Files {
		if !filepath.IsLocal(name) {
			return fmt.Errorf("unsafe installed marker path %q", name)
		}
		got, err := digest(filepath.Join(target, name))
		if err != nil || got != want {
			return fmt.Errorf("installed %s was edited; preserve your changes before reinstalling", name)
		}
	}
	return nil
}

// stageInstall validates and stages every file before replacing an owned copy.
// It retains the previous installation and restores it if the final rename fails.
func stageInstall(source, target string, validate func(string) error) (string, error) {
	if err := validateOwned(target, source); err != nil {
		return "", err
	}
	for _, name := range installFiles {
		info, err := os.Lstat(filepath.Join(source, name))
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("install source must be a regular file: %s", name)
		}
		if name == "yakker-controller" && info.Mode().Perm()&0111 == 0 {
			return "", fmt.Errorf("yakker-controller is not executable; run make build first")
		}
	}
	parent := filepath.Dir(target)
	if err := os.MkdirAll(parent, 0755); err != nil {
		return "", err
	}
	temp, err := os.MkdirTemp(parent, ".yakker-stage-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temp)
	stage := filepath.Join(temp, radio.PluginID)
	if err = os.Mkdir(stage, 0755); err != nil {
		return "", err
	}
	marker := installMarker{Source: source, Files: map[string]string{}}
	for _, name := range installFiles {
		src := filepath.Join(source, name)
		dst := filepath.Join(stage, name)
		data, err := os.ReadFile(src)
		if err != nil {
			return "", err
		}
		info, err := os.Stat(src)
		if err != nil {
			return "", err
		}
		if err = os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
			return "", err
		}
		if err = os.WriteFile(dst, data, info.Mode().Perm()); err != nil {
			return "", err
		}
		checksum, err := digest(dst)
		if err != nil {
			return "", err
		}
		marker.Files[name] = checksum
	}
	data, err := json.MarshalIndent(marker, "", "  ")
	if err != nil {
		return "", err
	}
	if err = os.WriteFile(filepath.Join(stage, ".local-source.json"), append(data, '\n'), 0644); err != nil {
		return "", err
	}
	if err = validate(stage); err != nil {
		return "", err
	}
	// Recheck after staging so edits made during preparation are not overwritten.
	if err = validateOwned(target, source); err != nil {
		return "", err
	}
	backup := ""
	if _, err = os.Lstat(target); err == nil {
		backupRoot := filepath.Join(filepath.Dir(parent), "plugin-backups")
		if err = os.MkdirAll(backupRoot, 0700); err != nil {
			return "", err
		}
		backup = filepath.Join(backupRoot, filepath.Base(target)+"-"+time.Now().Format("20060102-150405.000000000"))
		if err = os.Rename(target, backup); err != nil {
			return "", err
		}
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if err = os.Rename(stage, target); err != nil {
		if backup != "" {
			if restoreErr := os.Rename(backup, target); restoreErr != nil {
				return "", fmt.Errorf("install failed: %v; restoring %s failed: %w", err, backup, restoreErr)
			}
		}
		return "", err
	}
	return backup, nil
}

func Install(root string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	if _, err = command("omarchy", "plugin", "validate", root); err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	target := filepath.Join(home, ".config/omarchy/plugins", radio.PluginID)
	backup, err := stageInstall(root, target, func(stage string) error { _, err := command("omarchy", "plugin", "validate", stage); return err })
	if err != nil {
		return err
	}
	fmt.Println("Installed", radio.PluginID, "into", target)
	if backup != "" {
		fmt.Println("Previous installation saved at", backup)
	}
	if _, err = command("omarchy-shell", "shell", "rescanPlugins"); err != nil {
		return err
	}
	discovered := false
	for i := 0; i < 40; i++ {
		output, err := command("omarchy", "plugin", "list", "--json")
		if err != nil {
			return err
		}
		var plugins []struct {
			ID string `json:"id"`
		}
		if err = json.Unmarshal([]byte(output), &plugins); err != nil {
			return err
		}
		for _, p := range plugins {
			if p.ID == radio.PluginID {
				discovered = true
			}
		}
		if discovered {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !discovered {
		return fmt.Errorf("shell did not discover Yakker after rescan")
	}
	if _, err = command("omarchy", "plugin", "enable", radio.PluginID); err != nil {
		return err
	}
	for i := 0; i < 40; i++ {
		output, err := command("omarchy-shell", radio.PluginID, "status")
		var status struct {
			Ready bool `json:"ready"`
		}
		if err == nil && json.Unmarshal([]byte(output), &status) == nil && status.Ready {
			fmt.Println("Yakker is ready. Click its bar icon and choose a station, then Play live.")
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("widget installed, but helper not ready; after a controller update, stop playback and restart the shell to load the new code")
}
