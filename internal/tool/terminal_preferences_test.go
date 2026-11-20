package tool

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/joega/yakker/internal/radio"
)

func TestTerminalSelectionRestoresOnlyDefaultCatalogue(t *testing.T) {
	root := stationFixture(t)
	path, err := terminalPreferencePath()
	if err != nil {
		t.Fatal(err)
	}
	check := func(options listenOptions, want string, persistent bool) {
		t.Helper()
		setup, err := preparePlayback(root, options, radio.Config{})
		if err != nil {
			t.Fatal(err)
		}
		defer setup.close()
		id, _ := setup.selected["id"].(string)
		if id != want || (setup.remember != nil) != persistent {
			t.Fatalf("selection=%q persistent=%v; want %q %v", id, setup.remember != nil, want, persistent)
		}
	}
	check(listenOptions{}, "", true)
	if err = saveTerminalStation(path, "second"); err != nil {
		t.Fatal(err)
	}
	check(listenOptions{}, "second", true)
	check(listenOptions{station: "first"}, "first", true)
	check(listenOptions{stationFile: filepath.Join(root, "stations.json")}, "", false)
	check(listenOptions{stationFile: filepath.Join(root, "stations.json"), station: "first"}, "first", false)
	check(listenOptions{streamURL: "https://example.test/live"}, "cli", false)
	if err = saveTerminalStation(path, "deleted-station"); err != nil {
		t.Fatal(err)
	}
	check(listenOptions{}, "", true)
	if err = os.WriteFile(path, []byte(strings.Repeat("x", maxTerminalPreferenceBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	check(listenOptions{}, "", true)
}

func TestListenNeedsChoiceBeforeStartingController(t *testing.T) {
	root := stationFixture(t)
	path, _ := terminalPreferencePath()
	for _, missing := range []string{"", "deleted-station"} {
		if missing != "" {
			if err := saveTerminalStation(path, missing); err != nil {
				t.Fatal(err)
			}
		}
		err := listen(context.Background(), root, listenOptions{}, radio.Config{}, strings.NewReader(""), io.Discard, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error {
			t.Error("started controller without a chosen station")
			return nil
		})
		if err == nil || !strings.Contains(err.Error(), "--station") || !strings.Contains(err.Error(), "--list-stations") {
			t.Fatal(err)
		}
	}
}

func TestTerminalPreferencesAtomicPrivateAndBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yakker", "terminal.json")
	for _, id := range []string{"first", "second"} {
		if err := saveTerminalStation(path, id); err != nil {
			t.Fatal(err)
		}
		if got := loadTerminalStation(path); got != id {
			t.Fatal(got)
		}
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("mode: %v %v", info, err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary files: %v %v", entries, err)
	}
	if err := saveTerminalStation(path, strings.Repeat("x", 513)); err == nil {
		t.Fatal("accepted oversized station ID")
	}
	if loadTerminalStation(path) != "second" {
		t.Fatal("failed save replaced choice")
	}
}

func TestListenRemembersAcknowledgedChoiceAndRestoresIt(t *testing.T) {
	root := stationFixture(t)
	path, _ := terminalPreferencePath()
	first := &consolePeer{}
	h := startConsole(t, root, listenOptions{station: "second", volume: 60}, radio.Config{}, first.run)
	h.output.wait(t, 0, "Second station · Playing")
	h.send(t, "quit", "")
	h.finish(t)
	if got := loadTerminalStation(path); got != "second" {
		t.Fatal("did not save chosen station", got)
	}
	restored := &consolePeer{}
	h = startConsole(t, root, listenOptions{volume: 60}, radio.Config{}, restored.run)
	h.output.wait(t, 0, "Second station · Playing")
	h.send(t, "quit", "")
	h.finish(t)
	if restored.commands[0]["stationId"] != "second" {
		t.Fatal(restored.commands)
	}
	isolated := &consolePeer{}
	h = startConsole(t, root, listenOptions{stationFile: filepath.Join(root, "stations.json"), station: "first", volume: 60}, radio.Config{}, isolated.run)
	h.output.wait(t, 0, "First station · Playing")
	h.send(t, "quit", "")
	h.finish(t)
	if got := loadTerminalStation(path); got != "second" {
		t.Fatal("alternate catalogue overwrote choice", got)
	}
}

func TestListenFailureBeforeAcknowledgementDoesNotReplaceLastChoice(t *testing.T) {
	root := stationFixture(t)
	path, _ := terminalPreferencePath()
	if err := saveTerminalStation(path, "second"); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("controller failed")
	err := listen(context.Background(), root, listenOptions{station: "first"}, radio.Config{}, strings.NewReader(""), io.Discard, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error { return failure })
	if !errors.Is(err, failure) {
		t.Fatal(err)
	}
	if got := loadTerminalStation(path); got != "second" {
		t.Fatal("failed choice overwrote preference", got)
	}
}

func TestListenRemembersConfigureAcknowledgementDespiteConnectionFailure(t *testing.T) {
	root := stationFixture(t)
	path, _ := terminalPreferencePath()
	if err := saveTerminalStation(path, "second"); err != nil {
		t.Fatal(err)
	}
	runner := func(ctx context.Context, cfg radio.Config, input io.Reader, output, logs io.Writer) error {
		stations, err := radio.LoadStations(cfg.StationFile)
		if err != nil {
			return err
		}
		decoder, encoder := json.NewDecoder(input), json.NewEncoder(output)
		for {
			var command map[string]any
			if err := decoder.Decode(&command); err != nil {
				if err == io.EOF || ctx.Err() != nil {
					return nil
				}
				return err
			}
			serial := int64(command["serial"].(float64))
			state := radio.Status{Serial: serial, Station: stations[0], State: "error", Error: "stream unavailable"}
			if err := encoder.Encode(state); err != nil {
				return err
			}
		}
	}
	h := startConsole(t, root, listenOptions{station: "first"}, radio.Config{}, runner)
	h.output.wait(t, 0, "stream unavailable")
	h.send(t, "quit", "")
	h.finish(t)
	if got := loadTerminalStation(path); got != "first" {
		t.Fatal("connection failure discarded acknowledged station", got)
	}
}

func TestMalformedChoiceAndStatusDoNotReplaceLastChoice(t *testing.T) {
	root := stationFixture(t)
	path, _ := terminalPreferencePath()
	if err := saveTerminalStation(path, "second"); err != nil {
		t.Fatal(err)
	}
	err := listen(context.Background(), root, listenOptions{station: "missing"}, radio.Config{}, strings.NewReader(""), io.Discard, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error {
		t.Error("unknown station started controller")
		return nil
	})
	if err == nil {
		t.Fatal("accepted missing station")
	}
	input, writer := io.Pipe()
	defer writer.Close()
	err = listen(context.Background(), root, listenOptions{station: "first"}, radio.Config{}, input, io.Discard, io.Discard, func(ctx context.Context, cfg radio.Config, input io.Reader, output, logs io.Writer) error {
		decoder := json.NewDecoder(input)
		for {
			var command map[string]any
			if err := decoder.Decode(&command); err != nil {
				if err == io.EOF || ctx.Err() != nil {
					return nil
				}
				return err
			}
			if command["serial"] == float64(4) {
				if _, err := io.WriteString(output, "malformed status\n"); err != nil {
					return err
				}
			}
		}
	})
	if err == nil {
		t.Fatal("accepted malformed status")
	}
	if got := loadTerminalStation(path); got != "second" {
		t.Fatal("unacknowledged choice overwrote preference", got)
	}
}

func TestFreshTUIRequiresEnterAndRemembersAcknowledgedChoiceDespiteConnectionFailure(t *testing.T) {
	m, controls := modelFixture()
	m = newTUIModel(m.stations, "", listenOptions{volume: 60}, controls.send, nil)
	if m.wanted || m.target != "" || m.status.Station != nil || !strings.Contains(m.View().Content, "Choose a station") {
		t.Fatal("fresh TUI selected a broadcaster", m)
	}
	m = updateModel(m, key(tea.KeySpace))
	if len(controls.commands) != 0 {
		t.Fatal("Space chose a station", controls.commands)
	}
	m = updateModel(m, key(tea.KeyDown))
	if len(controls.commands) != 0 {
		t.Fatal("navigation tuned a station")
	}
	var saved []string
	m.remember = func(id string) error { saved = append(saved, id); return nil }
	m = updateModel(m, key(tea.KeyEnter))
	serial := controls.serial
	if len(controls.commands) != 2 || !m.wanted || m.target != "second" {
		t.Fatal(controls.commands)
	}
	m = updateModel(m, statusMessage(m.stations[1], serial-1, 60, false, true))
	m = updateModel(m, statusMessage(m.stations[0], serial, 60, false, true))
	if len(saved) != 0 {
		t.Fatal("remembered stale or different station", saved)
	}
	failure := statusMessage(m.stations[1], serial, 60, false, false)
	failure.status.State = "error"
	failure.status.Error = "unavailable"
	m = updateModel(m, failure)
	if len(saved) != 1 || saved[0] != "second" {
		t.Fatal("connection failure discarded acknowledged choice", saved)
	}
	m = updateModel(m, statusMessage(m.stations[1], serial, 60, false, true))
	m = updateModel(m, statusMessage(m.stations[1], serial, 60, false, true))
	if len(saved) != 1 || saved[0] != "second" {
		t.Fatal(saved)
	}
	// A later choice cannot be overwritten by a delayed acknowledgement.
	m = updateModel(m, key(tea.KeyDown))
	m = updateModel(m, key(tea.KeyEnter))
	m = updateModel(m, statusMessage(m.stations[1], serial, 60, false, true))
	if len(saved) != 1 {
		t.Fatal("remembered stale acknowledgement", saved)
	}
	controls.fail = true
	m = updateModel(m, key(tea.KeyUp))
	m = updateModel(m, key(tea.KeyEnter))
	if len(saved) != 1 {
		t.Fatal("remembered failed command")
	}
}

func TestTUIRememberFailureIsVisible(t *testing.T) {
	m, _ := modelFixture()
	m.remember = func(string) error { return errors.New("read only") }
	m = updateModel(m, statusMessage(m.stations[0], 4, 60, false, true))
	if !strings.Contains(m.notice, "Could not remember station") {
		t.Fatal(m.notice)
	}
}

func TestTUIFatalStatusBeforeAcknowledgementDoesNotRememberChoice(t *testing.T) {
	m, _ := modelFixture()
	m.remember = func(string) error {
		t.Error("remembered choice before valid acknowledgement")
		return nil
	}
	failure := errors.New("malformed controller status")
	m = updateModel(m, tuiStatusMsg(statusEvent{err: failure}))
	if !errors.Is(m.fatal, failure) {
		t.Fatal(m.fatal)
	}
}
