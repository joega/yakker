package tool

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"image/color"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/ansi"
	"github.com/joega/yakker/internal/radio"
)

type modelControls struct {
	serial   int64
	commands []map[string]any
	fail     bool
}

func (c *modelControls) send(action string, fields map[string]any) (int64, error) {
	if c.fail {
		return 0, errors.New("controls busy")
	}
	c.serial++
	command := map[string]any{"action": action, "serial": c.serial}
	for k, v := range fields {
		command[k] = v
	}
	c.commands = append(c.commands, command)
	return c.serial, nil
}
func modelFixture() (tuiModel, *modelControls) {
	stations := []radio.Station{
		{"id": "first", "name": "98.5 The Sports Hub", "subtitle": "WBZ-FM · Boston"},
		{"id": "second", "name": "Second station", "subtitle": "Another live stream"},
		{"id": "third", "name": "Third station", "subtitle": "Live radio"},
	}
	controls := &modelControls{serial: 4}
	m := newTUIModel(stations, "first", listenOptions{volume: 60}, controls.send, nil)
	m.ready = true
	m.status = radio.Status{State: "playing", Wanted: true, Volume: 60, Serial: 4, Station: stations[0]}
	return m, controls
}
func key(code rune) tea.KeyPressMsg                { return tea.KeyPressMsg(tea.Key{Code: code}) }
func updateModel(m tuiModel, msg tea.Msg) tuiModel { next, _ := m.Update(msg); return next.(tuiModel) }
func statusMessage(station radio.Station, serial int64, volume int, muted, wanted bool) tuiStatusMsg {
	state := "stopped"
	if wanted {
		state = "playing"
	}
	return tuiStatusMsg(statusEvent{status: radio.Status{State: state, Station: station, Serial: serial, Volume: volume, Muted: muted, Wanted: wanted}})
}

func TestTUIControlsPreserveIntentAcrossOldStatus(t *testing.T) {
	m, c := modelFixture()
	for i := 0; i < 3; i++ {
		m = updateModel(m, key(tea.KeyRight))
	}
	m = updateModel(m, statusMessage(m.stations[0], 5, 65, false, true))
	if m.volume != 75 {
		t.Fatal("old volume response undid input", m.volume)
	}
	m = updateModel(m, key('m'))
	m = updateModel(m, key('m'))
	m = updateModel(m, statusMessage(m.stations[0], 8, 75, true, true))
	if m.muted {
		t.Fatal("old mute response undid second toggle")
	}
	m = updateModel(m, key(tea.KeySpace))
	m = updateModel(m, statusMessage(m.stations[0], 4, 60, false, true))
	if m.wanted {
		t.Fatal("old playback response undid Stop")
	}
	m = updateModel(m, key(tea.KeySpace))
	if !m.wanted {
		t.Fatal("Space failed to restart")
	}
	if c.commands[len(c.commands)-2]["action"] != "stop" || c.commands[len(c.commands)-1]["action"] != "play" {
		t.Fatal(c.commands)
	}
	for i := 0; i < 30; i++ {
		m = updateModel(m, key(tea.KeyRight))
	}
	if m.volume != 100 {
		t.Fatal("volume did not clamp")
	}
	for i := 0; i < 30; i++ {
		m = updateModel(m, key(tea.KeyLeft))
	}
	if m.volume != 0 {
		t.Fatal("volume did not clamp")
	}
}
func TestTUIStationSelectionRequiresEnterAndFencesOldLiveState(t *testing.T) {
	m, c := modelFixture()
	m = updateModel(m, key(tea.KeyDown))
	if m.cursor != 1 || len(c.commands) != 0 {
		t.Fatal("browsing changed playback")
	}
	m = updateModel(m, key(tea.KeyEnter))
	if len(c.commands) != 2 || c.commands[0]["action"] != "configure" || c.commands[0]["stationId"] != "second" || c.commands[1]["action"] != "play" {
		t.Fatal(c.commands)
	}
	m = updateModel(m, statusMessage(m.stations[0], 4, 60, false, true))
	if !m.pendingStation() || m.displayStation()["id"] != "second" {
		t.Fatal("old station overwrote tuning target")
	}
	if _, kind := m.badge(); kind == "live" {
		t.Fatal("claimed new station was live before acknowledgement")
	}
	m = updateModel(m, statusMessage(m.stations[1], 6, 60, false, true))
	if m.pendingStation() {
		t.Fatal("did not accept new station acknowledgement")
	}
	if _, kind := m.badge(); kind != "live" {
		t.Fatal("live state missing")
	}
	m = updateModel(m, key(tea.KeyDown))
	m = updateModel(m, key(tea.KeyDown))
	if m.cursor != 2 {
		t.Fatal("cursor exceeded list")
	}
}
func TestTUIBusyControlsDoNotChangeIntent(t *testing.T) {
	m, c := modelFixture()
	c.fail = true
	m = updateModel(m, key(tea.KeyRight))
	m = updateModel(m, key('m'))
	m = updateModel(m, key(tea.KeySpace))
	if m.volume != 60 || m.muted || !m.wanted || m.notice == "" {
		t.Fatal("failed command changed controls")
	}
}
func TestTUIRetryHelpThemeAndQuit(t *testing.T) {
	m, c := modelFixture()
	m = updateModel(m, key('r'))
	if c.commands[0]["action"] != "stop" || c.commands[1]["action"] != "play" {
		t.Fatal("Retry did not request fresh stream")
	}
	m = updateModel(m, key('?'))
	if !m.help {
		t.Fatal("help did not open")
	}
	m = updateModel(m, tea.BackgroundColorMsg{Color: color.White})
	if m.dark {
		t.Fatal("light theme not detected")
	}
	for _, msg := range []tea.KeyPressMsg{key('q'), key(tea.KeyEscape), tea.KeyPressMsg(tea.Key{Code: 'c', Mod: tea.ModCtrl})} {
		_, cmd := m.Update(msg)
		if cmd == nil {
			t.Fatal("missing Quit command")
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Fatal("did not quit")
		}
	}
}
func TestTUILayoutFitsTerminals(t *testing.T) {
	for _, size := range []struct{ width, height int }{{120, 40}, {80, 24}, {60, 22}, {48, 20}, {40, 14}, {32, 12}, {26, 9}, {12, 4}} {
		for _, help := range []bool{false, true} {
			t.Run(fmt.Sprintf("%dx%d/help=%t", size.width, size.height, help), func(t *testing.T) {
				m, _ := modelFixture()
				m.width = size.width
				m.height = size.height
				m.help = help
				m.status.Title = "Actual metadata with a long title 中文 and accents ééé"
				view := m.View()
				if !view.AltScreen {
					t.Fatal("missing alternate-screen lifecycle")
				}
				if width, height := lipgloss.Width(view.Content), lipgloss.Height(view.Content); width > size.width || height > size.height {
					t.Fatalf("layout %dx%d exceeds terminal %dx%d\n%s", width, height, size.width, size.height, ansi.Strip(view.Content))
				}
				if !strings.Contains(strings.ToLower(ansi.Strip(view.Content)), "quit") {
					t.Fatal("Quit hint disappeared")
				}
				m.status.Error = strings.Repeat("Stream unavailable. ", 10)
				errorView := m.View()
				if lipgloss.Width(errorView.Content) > size.width || lipgloss.Height(errorView.Content) > size.height {
					t.Fatalf("error overflow\n%s", ansi.Strip(errorView.Content))
				}
				if size.width == 80 && !help {
					t.Log("\n" + ansi.Strip(view.Content))
				}
			})
		}
	}
}
func TestTUIUntrustedMetadataCannotInjectTerminalControls(t *testing.T) {
	m, _ := modelFixture()
	m.status.Title = "show\x1b[2J\r\n\x07"
	m.status.Error = "error\x1b]52;c;payload\x07"
	view := m.View().Content
	for _, unsafe := range []string{"\x1b[2J", "\x1b]52", "\x07", "\r"} {
		if strings.Contains(view, unsafe) {
			t.Fatalf("untrusted terminal sequence %q", unsafe)
		}
	}
}
func TestTUIHelpListAndTerminalRequirement(t *testing.T) {
	var output bytes.Buffer
	if err := TUI(context.Background(), "", []string{"--help"}, strings.NewReader(""), &output, io.Discard); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "yakker tui") || !strings.Contains(output.String(), "enter tune") {
		t.Fatal(output.String())
	}
	output.Reset()
	if err := TUI(context.Background(), stationFixture(t), []string{"--list-stations"}, strings.NewReader(""), &output, io.Discard); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "Second station") {
		t.Fatal(output.String())
	}
	if err := TUI(context.Background(), "", nil, strings.NewReader(""), &output, io.Discard); err == nil || !strings.Contains(err.Error(), "interactive terminal") {
		t.Fatal(err)
	}
}

func TestTUISessionSerializesQueuedControls(t *testing.T) {
	peer := &consolePeer{}
	setup, err := preparePlayback(stationFixture(t), listenOptions{volume: 60}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer setup.close()
	session := startTUISession(context.Background(), setup.cfg, peer.run)
	defer session.close()
	for i := 0; i < 30; i++ {
		if _, err = session.send("volume", map[string]any{"value": i}); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.NewTimer(3 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case event := <-session.states:
			if event.err != nil {
				t.Fatal(event.err)
			}
			if event.status.Serial == 30 {
				if err = session.close(); err != nil {
					t.Fatal(err)
				}
				for i, c := range peer.commands {
					if c["serial"] != float64(i+1) || c["value"] != float64(i) {
						t.Fatalf("reordered command %d: %v", i, c)
					}
				}
				return
			}
		case <-deadline.C:
			t.Fatal("queued commands were not processed")
		}
	}
}
func TestTUISessionBackpressureAndCancellation(t *testing.T) {
	setup, err := preparePlayback(stationFixture(t), listenOptions{volume: 60}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer setup.close()
	session := startTUISession(context.Background(), setup.cfg, func(ctx context.Context, _ radio.Config, _ io.Reader, _ io.Writer, _ io.Writer) error {
		<-ctx.Done()
		return nil
	})
	defer session.close()
	busy := false
	for i := 0; i < 100; i++ {
		if _, err := session.send("volume", map[string]any{"value": i}); err != nil {
			busy = true
			break
		}
	}
	if !busy {
		t.Fatal("unbounded command queue")
	}
	done := make(chan error, 1)
	go func() { done <- session.close() }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("shutdown blocked behind input")
	}
}
func TestTUIProgramQuitWaitsForController(t *testing.T) {
	setup, err := preparePlayback(stationFixture(t), listenOptions{volume: 60}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	base := setup.cfg.RuntimeBase
	peer := &consolePeer{}
	err = runTUI(context.Background(), setup, listenOptions{volume: 60}, strings.NewReader("q"), io.Discard, peer.run, tea.WithoutRenderer(), tea.WithColorProfile(colorprofile.Ascii), tea.WithWindowSize(80, 24))
	if err != nil {
		t.Fatal(err)
	}
	setup.close()
	if _, err = os.Stat(base); !os.IsNotExist(err) {
		t.Fatal("runtime was not removed after program exit")
	}
}

func TestTUIWithRealMPV(t *testing.T) {
	if os.Getenv("YAKKER_TEST_REAL_MPV") != "1" {
		t.Skip("set YAKKER_TEST_REAL_MPV=1 for real-mpv TUI integration")
	}
	mpv, err := exec.LookPath("mpv")
	if err != nil {
		t.Fatal(err)
	}
	server, connections := testAudioServer(t)
	defer server.Close()
	root := t.TempDir()
	stations := []radio.Station{
		{"id": "first", "name": "First local stream", "subtitle": "Fixture", "streamUrl": server.URL + "/first.wav"},
		{"id": "second", "name": "Second local stream", "subtitle": "Fixture", "streamUrl": server.URL + "/second.wav"},
	}
	data, err := json.Marshal(stations)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(root, "stations.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	options := listenOptions{volume: 60}
	setup, err := preparePlayback(root, options, radio.Config{MPV: mpv, MPVArgs: []string{"--ao=null"}})
	if err != nil {
		t.Fatal(err)
	}
	defer setup.close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	session := startTUISession(ctx, setup.cfg, radio.Run)
	defer session.close()
	for _, c := range []struct {
		action string
		fields map[string]any
	}{{"configure", map[string]any{"stationId": "first"}}, {"volume", map[string]any{"value": 60}}, {"mute", map[string]any{"value": false}}, {"play", nil}} {
		if _, err = session.send(c.action, c.fields); err != nil {
			t.Fatal(err)
		}
	}
	observed := make(chan radio.Status, 128)
	filter := func(_ tea.Model, msg tea.Msg) tea.Msg {
		if event, ok := msg.(tuiStatusMsg); ok {
			observed <- statusEvent(event).status
		}
		return msg
	}
	model := newTUIModel(setup.stations, "first", options, session.send, session.states)
	program := tea.NewProgram(model, tea.WithInput(nil), tea.WithOutput(io.Discard), tea.WithoutRenderer(), tea.WithWindowSize(80, 24), tea.WithColorProfile(colorprofile.Ascii), tea.WithoutSignalHandler(), tea.WithContext(ctx), tea.WithFilter(filter))
	programDone := make(chan error, 1)
	go func() { _, err := program.Run(); programDone <- err }()
	t.Cleanup(func() { program.Kill(); cancel() })
	wait := func(predicate func(radio.Status) bool) radio.Status {
		t.Helper()
		timer := time.NewTimer(8 * time.Second)
		defer timer.Stop()
		var last radio.Status
		for {
			select {
			case state := <-observed:
				last = state
				if predicate(state) {
					return state
				}
			case <-timer.C:
				t.Fatalf("TUI state timeout: %+v", last)
			}
		}
	}
	first := wait(func(s radio.Status) bool { return s.State == "playing" && s.Serial >= 4 })
	program.Send(key(tea.KeyRight))
	wait(func(s radio.Status) bool { return s.Volume == 65 })
	program.Send(key('m'))
	wait(func(s radio.Status) bool { return s.Muted })
	program.Send(key(tea.KeyDown))
	program.Send(key(tea.KeyEnter))
	second := wait(func(s radio.Status) bool { return s.State == "playing" && s.Station["id"] == "second" })
	if second.PlayerPID == first.PlayerPID {
		t.Fatal("tuning did not replace player")
	}
	program.Send(key(tea.KeySpace))
	wait(func(s radio.Status) bool { return s.State == "stopped" && !s.Wanted && s.PlayerPID == 0 })
	program.Send(key(tea.KeySpace))
	third := wait(func(s radio.Status) bool { return s.State == "playing" && s.Station["id"] == "second" })
	if third.PlayerPID == second.PlayerPID {
		t.Fatal("Play did not start fresh")
	}
	program.Send(key('q'))
	select {
	case err := <-programDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("TUI did not quit")
	}
	if err = session.close(); err != nil {
		t.Fatal(err)
	}
	if err = syscall.Kill(third.PlayerPID, 0); err == nil {
		t.Fatal("player survived UI cleanup")
	}
	if _, err = os.Stat(filepath.Join(setup.cfg.RuntimeBase, radio.PluginID, "mpv.sock")); !os.IsNotExist(err) {
		t.Fatal("socket survived UI cleanup")
	}
	if connections.Load() < 3 {
		t.Fatal("station/stop/play sequence did not reconnect")
	}
}

func TestTUIRetryDetailsKeepAttemptAndFailureVisible(t *testing.T) {
	m, _ := modelFixture()
	m.status.State = "retrying"
	m.status.Retry = 2
	m.status.RetryDelay = 2
	m.status.Error = "network interrupted"
	detail := m.playbackDetail()
	for _, text := range []string{"Retry 2 of 5", "2s", "network interrupted"} {
		if !strings.Contains(detail, text) {
			t.Fatal(detail)
		}
	}
}

func TestTUICompactMuteIsVisibleWithoutColor(t *testing.T) {
	m, _ := modelFixture()
	m.width = 40
	m.height = 14
	m.muted = true
	if !strings.Contains(ansi.Strip(m.View().Content), "Muted") {
		t.Fatal("compact view hid mute state")
	}
}

func TestBundledCatalogueNavigationAndCityLabels(t *testing.T) {
	stations, err := radio.LoadStations("../../stations.json")
	if err != nil {
		t.Fatal(err)
	}
	controls := &modelControls{serial: 4}
	model := newTUIModel(stations, "wbz-fm", listenOptions{volume: 60, muted: true}, controls.send, nil)
	model.width, model.height = 80, 24
	model = updateModel(model, key(tea.KeyEnd))
	view := ansi.Strip(model.View().Content)
	last := stations[len(stations)-1]
	if !strings.Contains(view, stationString(last, "name")+" · "+stationString(last, "city")) || !strings.Contains(view, fmt.Sprintf("%d / %d", len(stations), len(stations))) {
		t.Fatalf("last bundled station is not visible: %s", view)
	}
	model = updateModel(model, key(tea.KeyEnter))
	if model.target != last["id"] {
		t.Fatal("could not tune last station", model.target)
	}
	model = updateModel(model, key(tea.KeyHome))
	model = updateModel(model, key(tea.KeyEnter))
	if model.target != "wbz-fm" {
		t.Fatal("Home did not return to existing default", model.target)
	}
}

func TestTUIDVRPauseIntentAndLiveControls(t *testing.T) {
	m, c := modelFixture()
	m.status.BufferMinutes = 30
	m.status.DVR = true
	m.status.BufferStart = 10
	m.status.BufferEnd = 100
	m.status.Position = 80
	m = updateModel(m, key('p'))
	serial := c.serial
	if !m.paused || c.commands[len(c.commands)-1]["action"] != "pause" {
		t.Fatal("P did not pause", c.commands)
	}
	m = updateModel(m, statusMessage(m.stations[0], serial-1, 60, false, true))
	if !m.paused {
		t.Fatal("stale status undid Pause")
	}
	badge, _ := m.badge()
	if !strings.Contains(badge, "PAUSED") {
		t.Fatal(badge)
	}
	m = updateModel(m, key(']'))
	if c.commands[len(c.commands)-1]["action"] != "skip" || c.commands[len(c.commands)-1]["value"] != 30.0 {
		t.Fatal(c.commands)
	}
	m = updateModel(m, key('g'))
	if c.commands[len(c.commands)-1]["action"] != "live" || m.paused {
		t.Fatal("Go live did not resume")
	}
}

func TestTUILiveOnlyPauseAndStoppedShortcut(t *testing.T) {
	m, c := modelFixture()
	if m.status.BufferMinutes != 0 {
		t.Fatal("fixture must start in Live only")
	}
	m = updateModel(m, key('p'))
	serial := c.serial
	if !m.paused || c.commands[len(c.commands)-1]["action"] != "pause" {
		t.Fatal("Live only P did not request temporary pause", c.commands)
	}
	m = updateModel(m, statusMessage(m.stations[0], serial-1, 60, false, true))
	if !m.paused {
		t.Fatal("stale live status undid pause intent")
	}
	m = updateModel(m, key('p'))
	if m.paused || c.commands[len(c.commands)-1]["action"] != "play" {
		t.Fatal("second P did not resume", c.commands)
	}
	m = updateModel(m, key('s'))
	count := len(c.commands)
	m = updateModel(m, key('p'))
	if len(c.commands) != count || m.wanted {
		t.Fatal("Pause while stopped started playback")
	}
}
