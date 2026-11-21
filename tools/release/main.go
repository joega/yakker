// Release builds deterministic Linux binary archives without publishing them.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"time"
)

var bundleFiles = []string{
	"docs/yakker-bar-states.png", "docs/yakker-bar-tooltips.png",
	"manifest.json", "qmldir", "BarWidget.qml",
	"Panel.qml", "RadioService.qml", "RecordingNotices.js", "StationLogo.qml", "RecordingsView.qml", "FocusButton.qml", "FocusIcon.qml", "StationPicker.qml", "MarqueeText.qml", "StateCard.qml", "FocusTextField.qml", "FocusDropdown.qml", "FocusSlider.qml",
	"stations.json", "README.md", "LICENSE",
	"assets/wbns-fm.png", "assets/wkrk-fm.webp", "assets/kwfn-fm.webp",
	"assets/wzgc-fm.webp", "assets/kkfn-fm.webp", "assets/klac.png",
	"assets/krld-fm.webp", "assets/kfan.png", "assets/kiro-am.webp",
	"assets/sportsnet-590.png", "assets/tsn-690.png", "assets/talksport.png",
	"assets/talksport-2.png", "assets/bbc-radio-5-live.png", "assets/off-the-ball.png",
	"assets/README.md", "assets/sports-hub.png", "assets/weei-fm.png",
	"assets/wscr.webp", "assets/wxyt-fm.webp", "assets/espn-new-york.png",
	"assets/wfan.webp", "assets/wip-fm.webp", "assets/kdka-fm.png",
	"assets/tsn-1050.png", "docs/yakker-popup.png", "docs/yakker-stations.png", "docs/yakker-dvr.png",
	"docs/yakker-recordings.png", "docs/yakker-schedule.png", "docs/yakker-settings.png",
	"docs/yakker-recording-player.png", "docs/yakker-storage.png", "docs/screenshots.md",
	"docs/yakker-schedules.png", "docs/yakker-record-now.png", "docs/yakker-notifications.png",
	"docs/yakker-custom-station.png", "docs/yakker-sleep-timer.png", "docs/yakker-recording-details.png",
	"docs/yakker-empty-library.png", "docs/yakker-empty-search.png",
	"docs/yakker-connection-error.png", "docs/yakker-empty-stations.png",
}

type entry struct {
	data []byte
	mode int64
}
type module struct {
	Path, Version, Dir string
	Main               bool
	Replace            *module
}
type packageInfo struct{ Module *module }
type buildRecord struct {
	Version  string `json:"version"`
	Platform string `json:"platform"`
	Go       string `json:"go"`
}

var validVersion = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$`)

func main() {
	source := flag.String("source", ".", "source checkout")
	output := flag.String("output", "dist", "output directory")
	arch := flag.String("arch", runtime.GOARCH, "Linux architecture: amd64 or arm64")
	version := flag.String("version", "", "archive version (default: manifest.json)")
	flag.Parse()
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	path, err := release(ctx, *source, *output, *arch, *version)
	if err != nil {
		fmt.Fprintln(os.Stderr, "release:", err)
		os.Exit(1)
	}
	fmt.Println(path)
}
func release(ctx context.Context, source, output, arch, version string) (string, error) {
	if arch != "amd64" && arch != "arm64" {
		return "", errors.New("supported release architectures: amd64, arm64")
	}
	source, err := filepath.Abs(source)
	if err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(source, "manifest.json"))
	if err != nil {
		return "", err
	}
	var manifest struct {
		Version string `json:"version"`
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return "", err
	}
	if version == "" {
		version = manifest.Version
	}
	version = strings.TrimPrefix(version, "v")
	if version != manifest.Version {
		return "", errors.New("archive version must match manifest.json")
	}
	if !validVersion.MatchString(version) {
		return "", errors.New("version must be a semantic version, e.g. 1.1.1")
	}
	temp, err := os.MkdirTemp("", "yakker-release-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temp)
	env := append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux", "GOARCH="+arch)
	files := map[string]entry{}
	for _, name := range []string{"yakker-controller", "yakker"} {
		binary := filepath.Join(temp, name)
		command := exec.CommandContext(ctx, "go", "build", "-trimpath", "-buildvcs=false", "-ldflags=-s -w", "-o", binary, "./cmd/"+name)
		command.Dir = source
		command.Env = env
		if log, err := command.CombinedOutput(); err != nil {
			return "", fmt.Errorf("build %s for %s: %w: %s", name, arch, err, log)
		}
		data, err := os.ReadFile(binary)
		if err != nil {
			return "", err
		}
		files[name] = entry{data, 0755}
	}
	for _, name := range bundleFiles {
		path := filepath.Join(source, filepath.FromSlash(name))
		info, err := os.Lstat(path)
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("release source is not a regular file: %s", name)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return "", err
		}
		files[name] = entry{data, 0644}
	}
	notices, err := thirdPartyNotices(ctx, source, env)
	if err != nil {
		return "", err
	}
	files["THIRD_PARTY_NOTICES.txt"] = entry{notices, 0644}
	record := buildRecord{Version: version, Platform: "linux/" + arch, Go: runtime.Version()}
	data, err = json.MarshalIndent(record, "", "  ")
	if err != nil {
		return "", err
	}
	files["BUILDINFO.json"] = entry{append(data, '\n'), 0644}
	if err = os.MkdirAll(output, 0755); err != nil {
		return "", err
	}
	name := "yakker-" + version + "-linux-" + arch + ".tar.gz"
	destination := filepath.Join(output, name)
	staged, err := os.CreateTemp(output, ".release-*.tar.gz")
	if err != nil {
		return "", err
	}
	defer os.Remove(staged.Name())
	if err = staged.Chmod(0644); err != nil {
		staged.Close()
		return "", err
	}
	hash := sha256.New()
	if err = writeArchive(io.MultiWriter(staged, hash), files); err != nil {
		staged.Close()
		return "", err
	}
	if err = staged.Close(); err != nil {
		return "", err
	}
	if err = os.Rename(staged.Name(), destination); err != nil {
		return "", err
	}
	checksum := hex.EncodeToString(hash.Sum(nil)) + "  " + name + "\n"
	if err = os.WriteFile(destination+".sha256", []byte(checksum), 0644); err != nil {
		return "", err
	}
	return destination, nil
}

func thirdPartyNotices(ctx context.Context, source string, env []string) ([]byte, error) {
	command := exec.CommandContext(ctx, "go", "list", "-buildvcs=false", "-deps", "-json", "./cmd/yakker-controller", "./cmd/yakker")
	command.Dir = source
	command.Env = env
	var diagnostics bytes.Buffer
	command.Stderr = &diagnostics
	data, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("list binary dependencies: %w: %s", err, diagnostics.String())
	}
	modules := map[string]module{}
	decoder := json.NewDecoder(bytes.NewReader(data))
	for {
		var pkg packageInfo
		if err = decoder.Decode(&pkg); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
		if pkg.Module != nil && !pkg.Module.Main {
			modules[pkg.Module.Path] = *pkg.Module
		}
	}
	var out bytes.Buffer
	out.WriteString("Third-party notices for the compiled Yakker binaries\n\n")
	goLicense, err := os.ReadFile(filepath.Join(runtime.GOROOT(), "LICENSE"))
	if err != nil {
		return nil, err
	}
	fmt.Fprintf(&out, "Go standard library (%s)\n%s\n", runtime.Version(), goLicense)
	names := make([]string, 0, len(modules))
	for name := range modules {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		m := modules[name]
		directory := m.Dir
		if m.Replace != nil {
			directory = m.Replace.Dir
		}
		fmt.Fprintf(&out, "\n%s %s\n", m.Path, m.Version)
		found := false
		for _, file := range []string{"LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING", "COPYRIGHT", "NOTICE"} {
			text, err := os.ReadFile(filepath.Join(directory, file))
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return nil, err
			}
			fmt.Fprintf(&out, "\n%s\n%s\n", file, text)
			found = true
		}
		if !found {
			return nil, fmt.Errorf("no license notice found for binary dependency %s", m.Path)
		}
	}
	return out.Bytes(), nil
}
func writeArchive(destination io.Writer, files map[string]entry) error {
	compressed, err := gzip.NewWriterLevel(destination, gzip.BestCompression)
	if err != nil {
		return err
	}
	compressed.Header.ModTime = time.Unix(0, 0)
	compressed.Header.OS = 255
	archive := tar.NewWriter(compressed)
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		if !filepath.IsLocal(name) || strings.Contains(name, "\\") {
			_ = archive.Close()
			_ = compressed.Close()
			return fmt.Errorf("unsafe archive path %q", name)
		}
		file := files[name]
		header := &tar.Header{Name: "yakker/" + filepath.ToSlash(name), Mode: file.mode, Size: int64(len(file.data)), ModTime: time.Unix(0, 0), Typeflag: tar.TypeReg, Format: tar.FormatUSTAR}
		if err = archive.WriteHeader(header); err != nil {
			_ = archive.Close()
			_ = compressed.Close()
			return err
		}
		if _, err = archive.Write(file.data); err != nil {
			_ = archive.Close()
			_ = compressed.Close()
			return err
		}
	}
	return errors.Join(archive.Close(), compressed.Close())
}
