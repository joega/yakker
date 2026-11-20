package tool

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/joega/yakker/internal/radio"
)

func TestListenArguments(t *testing.T) {
	for _, tc := range []struct {
		name  string
		args  []string
		valid bool
	}{
		{"defaults", nil, true},
		{"buffer-off", []string{"--buffer", "0"}, true}, {"buffer-5", []string{"--buffer", "5"}, true}, {"buffer-15", []string{"--buffer", "15"}, true}, {"buffer-30", []string{"--buffer", "30"}, true},
		{"buffer-invalid", []string{"--buffer", "1"}, false}, {"buffer-negative", []string{"--buffer", "-5"}, false}, {"buffer-fraction", []string{"--buffer", "5.5"}, false}, {"station", []string{"--station", "wbz-fm", "--volume", "60", "--muted"}, true},
		{"url", []string{"--url", "https://example.test/live.aac"}, true}, {"list", []string{"--list-stations"}, true},
		{"low", []string{"--volume", "-1"}, false}, {"high", []string{"--volume", "101"}, false}, {"fraction", []string{"--volume", "1.5"}, false},
		{"conflict", []string{"--station", "wbz-fm", "--url", "https://example.test/live"}, false},
		{"local-file", []string{"--url", "file:///tmp/audio.wav"}, false}, {"bad-url", []string{"--url", "https:///live"}, false},
		{"extra", []string{"wbz-fm"}, false}, {"unknown-flag", []string{"--bogus"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			opts, err := parseListenOptions(tc.args, io.Discard)
			if (err == nil) != tc.valid {
				t.Fatalf("options=%+v err=%v", opts, err)
			}
			if len(tc.args) == 0 && opts.volume != 60 {
				t.Fatal("default should be 60%")
			}
		})
	}
	var output bytes.Buffer
	if err := Listen(context.Background(), "", []string{"--help"}, strings.NewReader(""), &output, io.Discard); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), "--station") && !strings.Contains(output.String(), "-station") {
		t.Fatal(output.String())
	}
}

func stationFixture(t *testing.T) string {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	root := t.TempDir()
	data, _ := json.Marshal([]radio.Station{
		{"id": "first", "name": "First station", "subtitle": "Fixture", "streamUrl": "https://example.test/first"},
		{"id": "second", "name": "Second station", "subtitle": "Fixture", "streamUrl": "https://example.test/second"},
	})
	if err := os.WriteFile(filepath.Join(root, "stations.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestDefaultCLIIncludesSavedStationsAndExplicitSourcesAreIsolated(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	root := stationFixture(t)
	id, err := radio.NewCustomStationID()
	if err != nil {
		t.Fatal(err)
	}
	path, err := radio.CustomStationPath()
	if err != nil {
		t.Fatal(err)
	}
	custom := radio.CustomStation{ID: id, Name: "Saved", StreamURL: "https://example.test/saved"}
	if err := radio.SaveCustomStations(path, []radio.CustomStation{custom}, nil); err != nil {
		t.Fatal(err)
	}
	setup, err := preparePlayback(root, listenOptions{station: id, volume: 60}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	defer setup.close()
	stations, err := radio.LoadStations(setup.cfg.StationFile)
	if err != nil || setup.selected["id"] != id || len(stations) != 3 || stations[2]["id"] != id {
		t.Fatalf("merged snapshot: %#v %v", stations, err)
	}
	var output bytes.Buffer
	if err := Listen(context.Background(), root, []string{"--list-stations"}, strings.NewReader(""), &output, io.Discard); err != nil || !strings.Contains(output.String(), id) {
		t.Fatalf("list: %s %v", output.String(), err)
	}
	_, err = preparePlayback(root, listenOptions{station: id, stationFile: filepath.Join(root, "stations.json")}, radio.Config{})
	if err == nil {
		t.Fatal("explicit station catalogue included saved station")
	}
	if err := os.WriteFile(path, []byte("bad"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := preparePlayback(root, listenOptions{}, radio.Config{}); err == nil {
		t.Fatal("default hid corrupt custom catalogue")
	}
	explicit, err := preparePlayback(root, listenOptions{stationFile: filepath.Join(root, "stations.json")}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	explicit.close()
	url, err := preparePlayback(root, listenOptions{streamURL: "https://example.test/audio"}, radio.Config{})
	if err != nil {
		t.Fatal(err)
	}
	url.close()
}

// The peer checks the CLI/controller boundary. Process/audio lifecycle itself
// is exercised by radio's suite and TestListenWithRealMPV below.
type consolePeer struct {
	cfg      radio.Config
	commands []map[string]any
}

func (p *consolePeer) run(ctx context.Context, cfg radio.Config, input io.Reader, output, logs io.Writer) error {
	p.cfg = cfg
	stations, err := radio.LoadStations(cfg.StationFile)
	if err != nil {
		return err
	}
	state := radio.Status{State: "stopped", Volume: 65}
	encoder := json.NewEncoder(output)
	if err = encoder.Encode(state); err != nil {
		return err
	}
	decoder := json.NewDecoder(input)
	for {
		var command map[string]any
		if err = decoder.Decode(&command); err != nil {
			if err == io.EOF || ctx.Err() != nil {
				return nil
			}
			return err
		}
		p.commands = append(p.commands, command)
		state.Serial = int64(command["serial"].(float64))
		switch command["action"] {
		case "configure":
			state.Station = nil
			for _, s := range stations {
				if s["id"] == command["stationId"] {
					state.Station = s
				}
			}
		case "play":
			state.State = "playing"
			state.Wanted = true
			state.PlayerPID = 123
		case "stop":
			state.State = "stopped"
			state.Wanted = false
			state.PlayerPID = 0
		case "volume":
			state.Volume = int(command["value"].(float64))
		case "mute":
			state.Muted = command["value"].(bool)
		}
		if err = encoder.Encode(state); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
}

type consoleOutput struct {
	sync.Mutex
	data    bytes.Buffer
	changed chan struct{}
}

func (w *consoleOutput) Write(p []byte) (int, error) {
	w.Lock()
	n, err := w.data.Write(p)
	w.Unlock()
	select {
	case w.changed <- struct{}{}:
	default:
	}
	return n, err
}
func (w *consoleOutput) text() string { w.Lock(); defer w.Unlock(); return w.data.String() }
func (w *consoleOutput) wait(t *testing.T, offset int, text string) {
	t.Helper()
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		got := w.text()
		if len(got) >= offset && strings.Contains(got[offset:], text) {
			return
		}
		select {
		case <-w.changed:
		case <-timer.C:
			t.Fatalf("missing %q in output: %s", text, got)
		}
	}
}

type consoleHarness struct {
	input  *io.PipeWriter
	output *consoleOutput
	done   chan error
	cancel context.CancelFunc
}

func startConsole(t *testing.T, root string, opts listenOptions, cfg radio.Config, runner controllerRunner) *consoleHarness {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	input, writer := io.Pipe()
	h := &consoleHarness{input: writer, output: &consoleOutput{changed: make(chan struct{}, 1)}, done: make(chan error, 1), cancel: cancel}
	go func() {
		err := listen(ctx, root, opts, cfg, input, h.output, io.Discard, runner)
		input.Close()
		h.done <- err
	}()
	t.Cleanup(func() {
		cancel()
		writer.Close()
		select {
		case err := <-h.done:
			h.done <- err
		case <-time.After(5 * time.Second):
			t.Error("CLI failed to shut down")
		}
	})
	return h
}
func (h *consoleHarness) send(t *testing.T, line, want string) {
	t.Helper()
	offset := len(h.output.text())
	if _, err := fmt.Fprintln(h.input, line); err != nil {
		t.Fatal(err)
	}
	if want != "" {
		h.output.wait(t, offset, want)
	}
}
func (h *consoleHarness) finish(t *testing.T) {
	t.Helper()
	select {
	case err := <-h.done:
		h.done <- err
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("CLI did not exit")
	}
}

func TestListenControlsAndIndependentRuntime(t *testing.T) {
	root := stationFixture(t)
	original := os.Getenv("XDG_RUNTIME_DIR")
	before, err := os.ReadFile(filepath.Join(root, "stations.json"))
	if err != nil {
		t.Fatal(err)
	}
	peer := &consolePeer{}
	h := startConsole(t, root, listenOptions{station: "second", volume: 60}, radio.Config{}, peer.run)
	h.output.wait(t, 0, "Second station · Playing · Volume 60%")
	h.send(t, "volume 37", "Playing · Volume 37%")
	h.send(t, "mute", "Volume 37% · Muted")
	h.send(t, "unmute", "Playing · Volume 37%\n")
	h.send(t, "stop", "Stopped · Volume 37%")
	h.send(t, "play", "Playing · Volume 37%")
	h.send(t, "volume nope", "Volume must be an integer")
	h.send(t, "volume 999", "Volume must be an integer")
	h.send(t, "nonsense", "Unknown command")
	h.send(t, "help", "Commands:")
	h.send(t, "status", "Playing · Volume 37%")
	h.send(t, "quit", "")
	h.finish(t)
	if os.Getenv("XDG_RUNTIME_DIR") != original {
		t.Fatal("changed audio runtime environment")
	}
	if peer.cfg.RuntimeBase == original || peer.cfg.RuntimeBase == "" {
		t.Fatal("reused widget runtime")
	}
	if _, err = os.Stat(peer.cfg.RuntimeBase); !os.IsNotExist(err) {
		t.Fatal("left private runtime directory behind")
	}
	after, err := os.ReadFile(filepath.Join(root, "stations.json"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("modified station configuration")
	}
	want := []string{"configure", "volume", "mute", "play", "volume", "mute", "mute", "stop", "play", "status"}
	var got []string
	for _, c := range peer.commands {
		got = append(got, c["action"].(string))
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("commands=%v want=%v", got, want)
	}
	if peer.commands[0]["stationId"] != "second" || peer.commands[1]["value"] != float64(60) {
		t.Fatal("did not configure before playback")
	}
	if strings.Contains(h.output.text(), `{"state"`) {
		t.Fatal("raw JSON leaked into CLI")
	}
}

func TestListenCustomURLDoesNotNeedOrChangeStationFile(t *testing.T) {
	peer := &consolePeer{}
	h := startConsole(t, t.TempDir(), listenOptions{streamURL: "https://example.test/custom", volume: 25, muted: true}, radio.Config{}, peer.run)
	h.output.wait(t, 0, "Playing · Volume 25% · Muted")
	h.send(t, "quit", "")
	h.finish(t)
	if !strings.HasPrefix(peer.cfg.StationFile, peer.cfg.RuntimeBase+string(os.PathSeparator)) {
		t.Fatal("custom station was not temporary")
	}
}
func TestListenListsWithoutLaunchingController(t *testing.T) {
	root := stationFixture(t)
	var output bytes.Buffer
	err := listen(context.Background(), root, listenOptions{list: true}, radio.Config{}, strings.NewReader(""), &output, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error {
		t.Error("launched controller while listing")
		return nil
	})
	if err != nil || !strings.Contains(output.String(), "second\tSecond station") {
		t.Fatalf("%v %s", err, &output)
	}
}
func TestListenRejectsUnknownStationBeforeLaunching(t *testing.T) {
	err := listen(context.Background(), stationFixture(t), listenOptions{station: "missing"}, radio.Config{}, strings.NewReader(""), io.Discard, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error {
		t.Error("launched player for unknown station")
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "unknown station") {
		t.Fatal(err)
	}
}
func TestListenEOFAndCancellation(t *testing.T) {
	for _, mode := range []string{"eof", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			peer := &consolePeer{}
			h := startConsole(t, stationFixture(t), listenOptions{station: "first", volume: 60}, radio.Config{}, peer.run)
			h.output.wait(t, 0, "Playing")
			if mode == "eof" {
				h.input.Close()
			} else {
				h.cancel()
			}
			h.finish(t)
		})
	}
}
func TestListenControllerFailurePropagates(t *testing.T) {
	failure := errors.New("fixture controller failed")
	err := listen(context.Background(), stationFixture(t), listenOptions{station: "first", volume: 60}, radio.Config{}, strings.NewReader(""), io.Discard, io.Discard, func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error { return failure })
	if !errors.Is(err, failure) {
		t.Fatal(err)
	}
}
func TestListenSanitizesMetadata(t *testing.T) {
	text := formatListenStatus(radio.Status{State: "playing", Volume: 60, Station: radio.Station{"name": "Station\x1b[2J"}, Title: "show\n\r\x1b[31m", Error: "bad\x1b[0m"})
	if strings.ContainsAny(text, "\x1b\r") {
		t.Fatal("terminal controls in output", text)
	}
	if !strings.Contains(text, "Playback error:") {
		t.Fatal(text)
	}
}

func TestListenWithRealMPV(t *testing.T) {
	if os.Getenv("YAKKER_TEST_REAL_MPV") != "1" {
		t.Skip("set YAKKER_TEST_REAL_MPV=1 for local real-mpv CLI test")
	}
	mpv, err := exec.LookPath("mpv")
	if err != nil {
		t.Fatal(err)
	}
	server, connections := testAudioServer(t)
	defer server.Close()
	var runtimeBase string
	runner := func(ctx context.Context, cfg radio.Config, input io.Reader, output, logs io.Writer) error {
		runtimeBase = cfg.RuntimeBase
		return radio.Run(ctx, cfg, input, output, logs)
	}
	h := startConsole(t, t.TempDir(), listenOptions{streamURL: server.URL + "/live.wav", volume: 60}, radio.Config{MPV: mpv, MPVArgs: []string{"--ao=null"}}, runner)
	h.output.wait(t, 0, "Playing · Volume 60%")
	h.send(t, "volume 35", "Playing · Volume 35%")
	h.send(t, "mute", "Volume 35% · Muted")
	h.send(t, "stop", "Stopped · Volume 35%")
	h.send(t, "play", "Playing · Volume 35%")
	h.send(t, "quit", "")
	h.finish(t)
	if _, err = os.Stat(runtimeBase); !os.IsNotExist(err) {
		t.Fatal("left controller runtime after Quit")
	}
	seen := connections.Load()
	if seen < 2 {
		t.Fatal("fresh Play did not reconnect")
	}
	time.Sleep(200 * time.Millisecond)
	if connections.Load() != seen {
		t.Fatal("reconnected after quitting")
	}
}

func TestListenAcknowledgesUnchangedControls(t *testing.T) {
	peer := &consolePeer{}
	h := startConsole(t, stationFixture(t), listenOptions{station: "first", volume: 60}, radio.Config{}, peer.run)
	h.output.wait(t, 0, "Playing · Volume 60%")
	h.send(t, "play", "Playing · Volume 60%")
	h.send(t, "volume 60", "Playing · Volume 60%")
	h.send(t, "unmute", "Playing · Volume 60%")
	h.send(t, "status", "Playing · Volume 60%")
	h.send(t, "quit", "")
	h.finish(t)
}

// A local live WAV source shared by CLI and terminal-UI integration tests.
func testAudioServer(t *testing.T) (*httptest.Server, *atomic.Int32) {
	t.Helper()
	var connections atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connections.Add(1)
		w.Header().Set("Content-Type", "audio/wav")
		header := make([]byte, 44)
		copy(header, "RIFF")
		binary.LittleEndian.PutUint32(header[4:], 0x7fffffff)
		copy(header[8:], "WAVEfmt ")
		binary.LittleEndian.PutUint32(header[16:], 16)
		binary.LittleEndian.PutUint16(header[20:], 1)
		binary.LittleEndian.PutUint16(header[22:], 2)
		binary.LittleEndian.PutUint32(header[24:], 44100)
		binary.LittleEndian.PutUint32(header[28:], 44100*4)
		binary.LittleEndian.PutUint16(header[32:], 4)
		binary.LittleEndian.PutUint16(header[34:], 16)
		copy(header[36:], "data")
		binary.LittleEndian.PutUint32(header[40:], 0x7ffffff0)
		if _, err := w.Write(header); err != nil {
			return
		}
		w.(http.Flusher).Flush()
		for {
			if _, err := w.Write(make([]byte, 44100*4/10)); err != nil {
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	}))
	return server, &connections
}

func TestListenDVRCommandsAndBufferOptOut(t *testing.T) {
	peer := &consolePeer{}
	h := startConsole(t, stationFixture(t), listenOptions{station: "first", volume: 60, bufferMinutes: 30}, radio.Config{}, peer.run)
	h.output.wait(t, 0, "Playing · Volume 60%")
	for _, line := range []string{"pause", "resume", "back", "forward 12.5", "live", "buffer 0"} {
		h.send(t, line, "Playing · Volume 60%")
	}
	for _, line := range []string{"back NaN", "forward Inf", "back -2"} {
		h.send(t, line, "Seek seconds must be a positive finite number")
	}
	h.send(t, "buffer 60", "Buffer must be 0, 5, 15 or 30 minutes")
	h.send(t, "quit", "")
	h.finish(t)
	if peer.cfg.DVRWindow != 30*time.Minute {
		t.Fatal("buffer flag did not configure controller", peer.cfg.DVRWindow)
	}
	var got []string
	for _, command := range peer.commands[4:] {
		got = append(got, command["action"].(string))
	}
	if fmt.Sprint(got) != "[pause play skip skip live configure]" {
		t.Fatal("incorrect DVR commands or invalid values accepted", got)
	}
	if peer.commands[6]["value"] != -30.0 || peer.commands[7]["value"] != 12.5 || peer.commands[9]["bufferMinutes"] != 0.0 {
		t.Fatal("DVR command values", peer.commands)
	}
}
