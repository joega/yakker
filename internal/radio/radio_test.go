package radio

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

var testBinary, controllerBinary, stationFile string

func TestMain(m *testing.M) {
	if len(os.Args) > 2 && os.Args[1] == "--fake-owner" {
		runtime.LockOSThread()
		cmd := exec.Command(os.Args[2])
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			os.Exit(1)
		}
		os.Exit(0)
	}
	if filepath.Base(os.Args[0]) == "mpv" || (len(os.Args) > 1 && os.Args[1] == "--fake-mpv") {
		os.Exit(fakeMPV())
	}
	testBinary, _ = os.Executable()
	root, _ := filepath.Abs("../..")
	stationFile = filepath.Join(root, "stations.json")
	dir, err := os.MkdirTemp("/tmp", "yakker-bin-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	controllerBinary = filepath.Join(dir, "yakker-controller")
	cmd := exec.Command("go", "build", "-o", controllerBinary, "./cmd/yakker-controller")
	cmd.Dir = root
	if output, err := cmd.CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "build test controller: %v\n%s", err, output)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	data, err := os.ReadFile(stationFile)
	if err == nil {
		err = os.WriteFile(filepath.Join(dir, "stations.json"), data, 0600)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// A deterministic Go mpv peer. It exercises the actual Unix-socket protocol,
// subprocess ownership, signals, metadata, buffering and MPRIS-like events.
func fakeMPV() int {
	var socket, mode, markerDir string
	volume := 65
	muted := false
	mode = os.Getenv("FAKE_MPV_MODE")
	markerDir = os.Getenv("FAKE_MPV_LOG")
	for _, arg := range os.Args[1:] {
		if strings.HasPrefix(arg, "--input-ipc-server=") {
			socket = strings.TrimPrefix(arg, "--input-ipc-server=")
		}
		if strings.HasPrefix(arg, "--volume=") {
			volume, _ = strconv.Atoi(strings.TrimPrefix(arg, "--volume="))
		}
		if arg == "--mute=yes" {
			muted = true
		}
		if strings.HasPrefix(arg, "--fixture-mode=") {
			mode = strings.TrimPrefix(arg, "--fixture-mode=")
		}
	}
	if mode == "no-socket" {
		time.Sleep(10 * time.Second)
		return 0
	}
	marker := ""
	if markerDir != "" {
		marker = filepath.Join(markerDir, strconv.Itoa(os.Getpid()))
		_ = os.WriteFile(marker, []byte(strings.Join(os.Args[1:], "\n")), 0600)
		defer os.Remove(marker)
	}
	if mode == "delay-socket" {
		time.Sleep(150 * time.Millisecond)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		return 2
	}
	defer listener.Close()
	ctx, cancel := signalContext()
	defer cancel()
	go func() { <-ctx.Done(); listener.Close() }()
	for {
		conn, err := listener.Accept()
		if err != nil {
			break
		}
		func() {
			defer conn.Close()
			encoder := json.NewEncoder(conn)
			emit := func(v map[string]any) { _ = encoder.Encode(v) }
			prop := func(name string, v any) { emit(map[string]any{"event": "property-change", "name": name, "data": v}) }
			if mode != "stall" {
				emit(map[string]any{"event": "playback-restart"})
			}
			scanner := bufio.NewScanner(conn)
			for scanner.Scan() {
				var input struct {
					Command []any `json:"command"`
				}
				if json.Unmarshal(scanner.Bytes(), &input) != nil || len(input.Command) < 3 {
					continue
				}
				command := input.Command
				if marker != "" {
					f, _ := os.OpenFile(marker, os.O_APPEND|os.O_WRONLY, 0600)
					if f != nil {
						_ = json.NewEncoder(f).Encode(command)
						f.Close()
					}
				}
				name, _ := command[2].(string)
				switch command[0] {
				case "observe_property":
					switch name {
					case "volume":
						prop(name, volume)
					case "mute":
						prop(name, muted)
					case "metadata":
						prop(name, map[string]any{"icy-title": "<b>Actual ICY title</b>"})
					case "pause":
						if mode == "pause" {
							prop(name, true)
						}
					case "core-idle":
						if mode == "buffer" {
							prop(name, true)
						}
					case "time-pos":
						if mode == "end-stop" {
							emit(map[string]any{"event": "end-file", "reason": "stop"})
							return
						}
					}
				case "set_property":
					name := command[1].(string)
					if name == "volume" {
						volume = int(command[2].(float64))
					}
					if name == "mute" {
						muted = command[2].(bool)
					}
					prop(name, command[2])
				}
			}
		}()
	}
	return 0
}

// os/signal is deliberately used by the peer too; SIGKILL bypasses cleanup and
// is asserted separately, rather than treating a marker as a live process.
func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
}

type safeBuffer struct {
	sync.Mutex
	buffer bytes.Buffer
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.Lock()
	defer b.Unlock()
	return b.buffer.Write(p)
}
func (b *safeBuffer) String() string { b.Lock(); defer b.Unlock(); return b.buffer.String() }

type harness struct {
	t       *testing.T
	input   io.WriteCloser
	states  chan Status
	history []Status
	done    chan error
	cancel  context.CancelFunc
	base    string
	logs    *safeBuffer
	pid     int
	serial  int64
}

func tempDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "r-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return dir
}
func newHarness(t *testing.T, cfg Config, subprocess bool) *harness {
	t.Helper()
	h := &harness{t: t, states: make(chan Status, 256), done: make(chan error, 1), base: tempDir(t), logs: &safeBuffer{}}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	var output io.ReadCloser
	if subprocess {
		if err := os.Symlink(testBinary, filepath.Join(h.base, "mpv")); err != nil {
			t.Fatal(err)
		}
		cmd := exec.Command(controllerBinary)
		if os.Getenv("YAKKER_FAKE_OWNER") == "1" {
			cmd = exec.Command(testBinary, "--fake-owner", controllerBinary)
		}
		cmd.Env = append(os.Environ(), "XDG_RUNTIME_DIR="+h.base, "PATH="+h.base+":"+os.Getenv("PATH"), "GORACE=atexit_sleep_ms=0")
		var err error
		h.input, err = cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		output, err = cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		cmd.Stderr = h.logs
		if err = cmd.Start(); err != nil {
			t.Fatal(err)
		}
		h.pid = cmd.Process.Pid
		go func() { h.done <- cmd.Wait() }()
	} else {
		cfg.RuntimeBase = h.base
		if cfg.StationFile == "" {
			cfg.StationFile = stationFile
		}
		if cfg.MPV == "" {
			cfg.MPV = testBinary
			cfg.MPVArgs = append([]string{"--fake-mpv"}, cfg.MPVArgs...)
		}
		inR, inW := io.Pipe()
		outR, outW := io.Pipe()
		h.input = inW
		output = outR
		go func() { err := Run(ctx, cfg, inR, outW, h.logs); inR.Close(); outW.Close(); h.done <- err }()
	}
	readerDone := make(chan struct{})
	go func() {
		defer close(h.states)
		scanner := bufio.NewScanner(output)
		for scanner.Scan() {
			var s Status
			if err := json.Unmarshal(scanner.Bytes(), &s); err != nil {
				continue
			}
			select {
			case h.states <- s:
			case <-readerDone:
				return
			}
		}
	}()
	t.Cleanup(func() {
		h.input.Close()
		h.cancel()
		select {
		case <-h.done:
		case <-time.After(6 * time.Second):
			if h.pid != 0 {
				_ = syscall.Kill(h.pid, syscall.SIGKILL)
			}
			t.Error("controller did not exit")
		}
		close(readerDone)
		output.Close()
		if _, err := os.Stat(filepath.Join(h.base, PluginID, "mpv.sock")); !os.IsNotExist(err) {
			t.Errorf("socket left after shutdown: %v", err)
		}
	})
	h.wait(func(s Status) bool { return s.State == "stopped" })
	return h
}
func (h *harness) send(action string, fields ...any) int64 {
	h.t.Helper()
	h.serial++
	data := map[string]any{"action": action, "serial": h.serial}
	for i := 0; i < len(fields); i += 2 {
		data[fields[i].(string)] = fields[i+1]
	}
	if err := json.NewEncoder(h.input).Encode(data); err != nil {
		h.t.Fatal(err)
	}
	return h.serial
}
func (h *harness) wait(predicate func(Status) bool) Status {
	h.t.Helper()
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	for {
		select {
		case s, ok := <-h.states:
			if !ok {
				h.t.Fatalf("controller exited; history=%+v logs=%s", h.history, h.logs.String())
			}
			h.history = append(h.history, s)
			if predicate(s) {
				return s
			}
		case <-timer.C:
			h.t.Fatalf("state timeout; history=%+v logs=%s", h.history, h.logs.String())
		}
	}
}
func (h *harness) barrier() Status {
	serial := h.send("status")
	return h.wait(func(s Status) bool { return s.Serial == serial })
}
func (h *harness) stop() Status {
	serial := h.send("stop")
	return h.wait(func(s Status) bool { return s.State == "stopped" && s.Serial == serial })
}
func (h *harness) play() Status {
	h.send("play")
	return h.wait(func(s Status) bool { return s.State == "playing" })
}

func TestPlayVolumeMuteStopFreshRestart(t *testing.T) {
	h := newHarness(t, Config{}, true)
	first := h.play()
	h.send("volume", "value", 37)
	h.wait(func(s Status) bool { return s.Volume == 37 })
	h.send("mute", "value", true)
	h.wait(func(s Status) bool { return s.Muted })
	h.send("mute", "value", false)
	unmuted := h.wait(func(s Status) bool { return !s.Muted })
	if unmuted.Volume != 37 {
		t.Fatal(unmuted)
	}
	h.stop()
	second := h.play()
	if first.PlayerPID == second.PlayerPID || second.Volume != 37 {
		t.Fatalf("not a fresh player preserving volume: %+v", second)
	}
}
func TestRepeatedPlayAndRapidStopWins(t *testing.T) {
	h := newHarness(t, Config{}, true)
	for i := 0; i < 30; i++ {
		h.send("play")
	}
	first := h.wait(func(s Status) bool { return s.State == "playing" })
	state := h.barrier()
	if state.PlayerPID != first.PlayerPID {
		t.Fatal("repeated Play changed player")
	}
	for i := 0; i < 20; i++ {
		h.send("stop")
		h.send("play")
	}
	h.stop()
	state = h.barrier()
	if state.Wanted || state.PlayerPID != 0 {
		t.Fatalf("Stop lost: %+v", state)
	}
	time.Sleep(150 * time.Millisecond)
	if state = h.barrier(); state.Wanted || state.PlayerPID != 0 {
		t.Fatalf("stale event revived player: %+v", state)
	}
}
func TestUnexpectedExitAndStopCancelsBackoff(t *testing.T) {
	h := newHarness(t, Config{}, true)
	first := h.play()
	if err := syscall.Kill(first.PlayerPID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	retry := h.wait(func(s Status) bool { return s.State == "retrying" })
	if retry.RetryDelay != 1 || !retry.Wanted {
		t.Fatal(retry)
	}
	h.stop()
	time.Sleep(1150 * time.Millisecond)
	if state := h.barrier(); state.State != "stopped" || state.PlayerPID != 0 {
		t.Fatal(state)
	}
}
func TestUnexpectedExitReconnects(t *testing.T) {
	h := newHarness(t, Config{RetryDelays: []time.Duration{10 * time.Millisecond}}, false)
	first := h.play()
	_ = syscall.Kill(first.PlayerPID, syscall.SIGKILL)
	h.wait(func(s Status) bool { return s.State == "retrying" })
	second := h.wait(func(s Status) bool { return s.State == "playing" })
	if second.PlayerPID == first.PlayerPID {
		t.Fatal("did not start fresh player")
	}
}
func TestEOFCleansUp(t *testing.T) {
	h := newHarness(t, Config{}, true)
	first := h.play()
	h.input.Close()
	select {
	case err := <-h.done:
		h.done <- err
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("EOF did not exit")
	}
	if err := syscall.Kill(first.PlayerPID, 0); err == nil {
		t.Fatal("player survived EOF")
	}
}
func TestSignalsCleanUp(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP} {
		t.Run(sig.String(), func(t *testing.T) {
			h := newHarness(t, Config{}, true)
			first := h.play()
			_ = syscall.Kill(h.pid, sig)
			select {
			case err := <-h.done:
				h.done <- err
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("signal did not exit")
			}
			if err := syscall.Kill(first.PlayerPID, 0); err == nil {
				t.Fatal("player survived signal")
			}
		})
	}
}
func TestAbruptHelperDeathSignalsPlayer(t *testing.T) {
	markerDir := tempDir(t)
	t.Setenv("FAKE_MPV_LOG", markerDir)
	h := newHarness(t, Config{}, true)
	h.play()
	_ = syscall.Kill(h.pid, syscall.SIGKILL)
	select {
	case err := <-h.done:
		h.done <- err
	case <-time.After(5 * time.Second):
		t.Fatal("helper did not die")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		entries, _ := os.ReadDir(markerDir)
		if len(entries) == 0 {
			// SIGKILL prevents the helper from removing its socket. The next lock owner
			// removes this stale socket before starting a fresh player.
			_ = os.Remove(filepath.Join(h.base, PluginID, "mpv.sock"))
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("player did not receive parent-death signal")
}
func TestSingleOwnerLock(t *testing.T) {
	h := newHarness(t, Config{}, true)
	cmd := exec.Command(controllerBinary)
	cmd.Env = append(os.Environ(), "XDG_RUNTIME_DIR="+h.base)
	output, err := cmd.CombinedOutput()
	if err == nil || !strings.Contains(string(output), "already owned") {
		t.Fatalf("duplicate owner accepted: %v %s", err, output)
	}
	h.play()
}
func TestInvalidInputSurvives(t *testing.T) {
	h := newHarness(t, Config{}, true)
	cases := []struct {
		action  string
		value   any
		message string
	}{{"volume", "$(touch /tmp/yakker-should-never-exist)", "finite number"}, {"volume", true, "finite number"}, {"volume", nil, "finite number"}, {"mute", "yes", "boolean"}, {"mute", nil, "boolean"}}
	for _, tc := range cases {
		h.send(tc.action, "value", tc.value)
		h.wait(func(s Status) bool { return strings.Contains(s.Error, tc.message) })
	}
	for _, raw := range []string{"", "null", "[]", "{broken", "{\"action\":\"play\",\"serial\":true}", "{\"action\":\"play\",\"serial\":1.5}"} {
		if _, err := fmt.Fprintln(h.input, raw); err != nil {
			t.Fatal(err)
		}
		h.wait(func(s Status) bool { return s.Error != "" })
	}
	h.play()
}
func TestBoundedBackoffAndTimeoutNeverClaimsPlaying(t *testing.T) {
	h := newHarness(t, Config{MPVArgs: []string{"--fixture-mode=stall"}, ConnectTimeout: 40 * time.Millisecond, RetryDelays: []time.Duration{10 * time.Millisecond, 20 * time.Millisecond, 40 * time.Millisecond}}, false)
	h.send("play")
	last := h.wait(func(s Status) bool { return s.State == "error" })
	if last.Wanted || last.Retry != 3 {
		t.Fatal(last)
	}
	var delays []float64
	for _, s := range h.history {
		if s.State == "playing" {
			t.Fatal("claimed playing without playback event")
		}
		if s.State == "retrying" {
			delays = append(delays, s.RetryDelay)
		}
	}
	if fmt.Sprint(delays) != "[0.01 0.02 0.04]" {
		t.Fatal(delays)
	}
}
func TestMissingMPVNoRetryStorm(t *testing.T) {
	h := newHarness(t, Config{MPV: "/missing/yakker-mpv"}, false)
	h.send("play")
	s := h.wait(func(s Status) bool { return s.State == "error" })
	if s.Retry != 0 || s.Wanted || !strings.Contains(s.Error, "mpv is missing") {
		t.Fatal(s)
	}
}
func TestPauseAndEndStopDoNotReconnect(t *testing.T) {
	for _, mode := range []string{"pause", "end-stop"} {
		t.Run(mode, func(t *testing.T) {
			h := newHarness(t, Config{MPVArgs: []string{"--fixture-mode=" + mode}, RetryDelays: []time.Duration{20 * time.Millisecond}}, false)
			h.send("play")
			h.wait(func(s Status) bool { return s.State == "stopped" && !s.Wanted && s.PlayerPID == 0 })
			time.Sleep(50 * time.Millisecond)
			if s := h.barrier(); s.State != "stopped" || s.Wanted || s.PlayerPID != 0 {
				t.Fatal(s)
			}
		})
	}
}
func TestMetadataAndBuffering(t *testing.T) {
	h := newHarness(t, Config{MPVArgs: []string{"--fixture-mode=buffer"}}, false)
	h.play()
	s := h.wait(func(s Status) bool { return s.Title == "<b>Actual ICY title</b>" })
	if s.Title == "" {
		t.Fatal(s)
	}
	h.wait(func(s Status) bool { return s.State == "connecting" && s.Title != "" })
}
func TestClampingAndBankersRounding(t *testing.T) {
	h := newHarness(t, Config{}, false)
	for _, tc := range []struct {
		input float64
		want  int
	}{{-12, 0}, {120, 100}, {36.5, 36}, {37.5, 38}} {
		serial := h.send("volume", "value", tc.input)
		s := h.wait(func(s Status) bool { return s.Serial == serial })
		if s.Volume != tc.want {
			t.Fatal(s)
		}
	}
}
func TestConfigureRestartsOnlyForChanges(t *testing.T) {
	h := newHarness(t, Config{}, false)
	first := h.play()
	serial := h.send("configure", "stationId", "wbz-fm", "mprisPlugin", "")
	same := h.wait(func(s Status) bool { return s.Serial == serial })
	if same.PlayerPID != first.PlayerPID {
		t.Fatal("unchanged configure restarted playback")
	}
	serial = h.send("configure", "mprisPlugin", "/nonexistent/plugin")
	invalid := h.wait(func(s Status) bool { return s.Serial == serial })
	if !strings.Contains(invalid.Error, "does not exist") || invalid.PlayerPID != first.PlayerPID {
		t.Fatal(invalid)
	}
	plugin := filepath.Join(h.base, "plugin.so")
	if err := os.WriteFile(plugin, []byte{}, 0600); err != nil {
		t.Fatal(err)
	}
	h.send("configure", "mprisPlugin", plugin)
	fresh := h.wait(func(s Status) bool { return s.State == "playing" && s.MPRIS })
	if fresh.PlayerPID == first.PlayerPID {
		t.Fatal("changed configuration did not reconnect")
	}
}
func TestPrivateRuntimeValidation(t *testing.T) {
	base := tempDir(t)
	if err := os.Chmod(base, 0755); err != nil {
		t.Fatal(err)
	}
	_, _, err := acquireRuntime(base)
	if err == nil {
		t.Fatal("accepted public runtime")
	}
	if err = os.Chmod(base, 0700); err != nil {
		t.Fatal(err)
	}
	elsewhere := tempDir(t)
	if err = os.Symlink(elsewhere, filepath.Join(base, PluginID)); err != nil {
		t.Fatal(err)
	}
	if _, _, err = acquireRuntime(base); err == nil {
		t.Fatal("accepted symlink runtime")
	}
}
func TestStationValidation(t *testing.T) {
	dir := tempDir(t)
	path := filepath.Join(dir, "stations.json")
	for _, data := range []string{`[]`, `null`, `[null]`, `[{"id":"x"}]`, `[{"id":"x","name":"x","subtitle":"x","streamUrl":"file:///tmp/a"}]`, `[{"id":"x","name":"x","subtitle":"x","streamUrl":"https://example.test"},{"id":"x","name":"y","subtitle":"y","streamUrl":"https://example.test"}]`} {
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadStations(path); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
	if _, err := LoadStations(stationFile); err != nil {
		t.Fatal(err)
	}
}

func TestRealMPVInterruptionReconnectAndStop(t *testing.T) {
	if os.Getenv("YAKKER_TEST_REAL_MPV") != "1" {
		t.Skip("set YAKKER_TEST_REAL_MPV=1 for real mpv/local HTTP check")
	}
	mpv, err := exec.LookPath("mpv")
	if err != nil {
		t.Fatal(err)
	}
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
		flusher := w.(http.Flusher)
		flusher.Flush()
		for i := 0; i < 12; i++ {
			if _, err := w.Write(make([]byte, 44100*4/4)); err != nil {
				return
			}
			flusher.Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(40 * time.Millisecond):
			}
		}
	}))
	defer server.Close()
	path := filepath.Join(tempDir(t), "stations.json")
	data, _ := json.Marshal([]Station{{"id": "fixture", "name": "Test stream", "subtitle": "Local network fixture", "streamUrl": server.URL + "/live.wav"}})
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, Config{StationFile: path, MPV: mpv, MPVArgs: []string{"--ao=null"}, StallTimeout: 600 * time.Millisecond}, false)
	h.play()
	h.wait(func(s Status) bool { return s.State == "retrying" })
	h.wait(func(s Status) bool { return s.State == "playing" })
	if connections.Load() < 2 {
		t.Fatal("did not reconnect to local stream")
	}
	h.stop()
	seen := connections.Load()
	time.Sleep(1200 * time.Millisecond)
	if connections.Load() != seen {
		t.Fatal("Stop allowed another connection")
	}
}

func TestRunExitsOnBrokenOutput(t *testing.T) {
	// The initial publication must fail immediately, without starting a player.
	cfg := Config{RuntimeBase: tempDir(t), StationFile: stationFile}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := Run(context.Background(), cfg, strings.NewReader(""), brokenWriter{}, io.Discard); err == nil {
		t.Fatal("ignored broken output")
	}
}

type brokenWriter struct{}

func (brokenWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

func TestAbruptOwnerDeathCleansUpHelperAndPlayer(t *testing.T) {
	markerDir := tempDir(t)
	t.Setenv("FAKE_MPV_LOG", markerDir)
	t.Setenv("YAKKER_FAKE_OWNER", "1")
	h := newHarness(t, Config{}, true)
	h.play()
	_ = syscall.Kill(h.pid, syscall.SIGKILL)
	select {
	case err := <-h.done:
		h.done <- err
	case <-time.After(5 * time.Second):
		t.Fatal("owner did not die")
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		entries, _ := os.ReadDir(markerDir)
		_, err := os.Stat(filepath.Join(h.base, PluginID, "mpv.sock"))
		if len(entries) == 0 && os.IsNotExist(err) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("helper/player did not clean up after owner death")
}

func TestStopDuringConnectingAndBackoff(t *testing.T) {
	for _, mode := range []string{"stall", "no-socket"} {
		t.Run(mode, func(t *testing.T) {
			h := newHarness(t, Config{MPVArgs: []string{"--fixture-mode=" + mode}}, false)
			h.send("play")
			h.wait(func(s Status) bool { return s.State == "connecting" && s.PlayerPID != 0 })
			s := h.stop()
			if s.Wanted || s.PlayerPID != 0 {
				t.Fatal(s)
			}
			time.Sleep(100 * time.Millisecond)
			if s = h.barrier(); s.State != "stopped" || s.Wanted {
				t.Fatal(s)
			}
		})
	}
}

func TestVolumeMuteWhileConnecting(t *testing.T) {
	h := newHarness(t, Config{MPVArgs: []string{"--fixture-mode=delay-socket"}}, false)
	h.send("play")
	h.wait(func(s Status) bool { return s.State == "connecting" && s.PlayerPID != 0 })
	h.send("volume", "value", 37)
	h.send("mute", "value", true)
	h.wait(func(s Status) bool { return s.State == "playing" && s.Volume == 37 && s.Muted })
	time.Sleep(50 * time.Millisecond)
	if s := h.barrier(); s.Volume != 37 || !s.Muted {
		t.Fatal(s)
	}
}
