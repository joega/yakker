// Package radio supervises one headless mpv process. A single event loop owns
// mutable state; reader/wait goroutines only deliver events to that loop.
package radio

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/joega/yakker/internal/recording"
)

type Station map[string]any

type Status struct {
	State                   string              `json:"state"`
	Wanted                  bool                `json:"wanted"`
	Error                   string              `json:"error"`
	Volume                  int                 `json:"volume"`
	Muted                   bool                `json:"muted"`
	Title                   string              `json:"title"`
	Station                 Station             `json:"station"`
	Stations                []Station           `json:"stations"`
	CustomStationError      string              `json:"customStationError"`
	CustomMutationSerial    int64               `json:"customMutationSerial"`
	CustomMutationOK        bool                `json:"customMutationOK"`
	Retry                   int                 `json:"retry"`
	RetryDelay              float64             `json:"retryDelay"`
	PlayerPID               int                 `json:"playerPid"`
	MPRIS                   bool                `json:"mpris"`
	Serial                  int64               `json:"serial"`
	Paused                  bool                `json:"paused"`
	BufferMinutes           int                 `json:"bufferMinutes"`
	TemporaryBuffer         bool                `json:"temporaryBuffer"`
	DVR                     bool                `json:"dvr"`
	Position                float64             `json:"position"`
	BufferStart             float64             `json:"bufferStart"`
	BufferEnd               float64             `json:"bufferEnd"`
	BufferExpired           bool                `json:"bufferExpired"`
	Recordings              *recording.Snapshot `json:"recordings,omitempty"`
	RecordingMutationSerial int64               `json:"recordingMutationSerial"`
	RecordingMutationOK     bool                `json:"recordingMutationOK"`
	RecordingError          string              `json:"recordingError"`
	PlaybackProgressError   string              `json:"playbackProgressError"`
	SchedulePreview         *recording.Schedule `json:"schedulePreview,omitempty"`
	SchedulePreviewSerial   int64               `json:"schedulePreviewSerial"`
	SchedulePreviewError    string              `json:"schedulePreviewError"`
	PlaybackKind            string              `json:"playbackKind"`
	RecordingID             string              `json:"recordingId"`
	RecordingTitle          string              `json:"recordingTitle"`
	Duration                float64             `json:"duration"`
	PlaybackSpeed           float64             `json:"playbackSpeed"`
	SleepRemaining          int                 `json:"sleepRemaining"`
}

// Config overrides are used by the standalone CLI and tests; normal plugin
// startup uses the executable's adjacent stations.json and the real mpv.
type Config struct {
	RuntimeBase           string
	StationFile           string
	CustomStationFile     string
	DisableCustomStations bool
	RecordingConfig       *recording.Config
	DisableRecordings     bool
	MPV                   string
	MPVArgs               []string
	ConnectTimeout        time.Duration
	StallTimeout          time.Duration
	RetryDelays           []time.Duration
	ResetAfter            time.Duration
	DVRWindow             time.Duration
	DVRPollInterval       time.Duration
	DVRBytes              int64
	Now                   func() time.Time
}

func LoadStations(path string) ([]Station, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var stations []Station
	if err := json.Unmarshal(data, &stations); err != nil {
		return nil, err
	}
	if len(stations) == 0 {
		return nil, errors.New("stations.json must contain a nonempty array")
	}
	seen := map[string]bool{}
	for _, station := range stations {
		for _, key := range []string{"id", "name", "subtitle", "streamUrl"} {
			value, ok := station[key].(string)
			if !ok || strings.TrimSpace(value) == "" {
				return nil, fmt.Errorf("Station requires a nonempty %s", key)
			}
		}
		id := station["id"].(string)
		if seen[id] {
			return nil, errors.New("Station IDs must be unique")
		}
		seen[id] = true
		u, err := url.Parse(station["streamUrl"].(string))
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
			return nil, errors.New("Station streamUrl must use HTTP or HTTPS")
		}
	}
	return stations, nil
}

func (c *Config) defaults() error {
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.StationFile == "" {
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		c.StationFile = filepath.Join(filepath.Dir(executable), "stations.json")
	}
	if c.MPV == "" {
		c.MPV = "mpv"
	}
	if c.ConnectTimeout == 0 {
		c.ConnectTimeout = 25 * time.Second
	}
	if c.StallTimeout == 0 {
		c.StallTimeout = 30 * time.Second
	}
	if c.ResetAfter == 0 {
		c.ResetAfter = time.Minute
	}
	if c.DVRWindow < 0 || c.DVRWindow > 30*time.Minute {
		return errors.New("Buffer window must be between zero and 30 minutes")
	}
	if c.DVRPollInterval <= 0 {
		c.DVRPollInterval = time.Second
	}
	if c.DVRBytes <= 0 {
		c.DVRBytes = dvrByteLimit(c.DVRWindow)
	}
	if c.RetryDelays == nil {
		c.RetryDelays = []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second}
	}
	return nil
}

type player struct {
	// Suppress older observed values until the latest control reaches mpv.
	pendingVolume  *int
	pendingMute    *bool
	pendingPause   *bool
	lastProgress   atomic.Int64
	lastIntake     atomic.Int64
	position       atomic.Uint64
	cacheMu        sync.Mutex
	cache          cacheWindow
	temporaryStart float64
	playbackSince  time.Duration
	cmd            *exec.Cmd
	conn           net.Conn
	done           chan struct{}
	closed         chan struct{}
	logs           *playerLog
	started        time.Time
	socketDeadline time.Time
}

type playerLog struct {
	sync.Mutex
	last    string
	output  io.Writer
	private bool
}

func (l *playerLog) Write(data []byte) (int, error) {
	l.Lock()
	defer l.Unlock()
	message := strings.TrimSpace(string(data))
	if message != "" {
		if l.private {
			message = "Custom stream reported a playback error."
		}
		l.last = tail(message, 300)
		fmt.Fprintln(l.output, "yakker/mpv:", l.last)
	}
	return len(data), nil
}
func (l *playerLog) message(fallback string) string {
	l.Lock()
	defer l.Unlock()
	if l.last != "" {
		return l.last
	}
	return fallback
}

// mpvEvent keeps the fixed event envelope typed while leaving property data
// flexible (numbers, booleans, metadata maps, or null). This avoids allocating a
// map and copies of every envelope key for each progress notification.
type mpvEvent struct {
	Event     string `json:"event"`
	Name      string `json:"name"`
	Data      any    `json:"data"`
	Reason    string `json:"reason"`
	FileError string `json:"file_error"`
}

type playerEvent struct {
	source *player
	value  mpvEvent
	err    error
}
type inputLine struct {
	data []byte
	eof  bool
	err  error
}

type controller struct {
	cfg            Config
	state          Status
	stations       []Station
	bundled        []Station
	custom         []CustomStation
	customPath     string
	customLoadErr  error
	socket         string
	mpris          string
	player         *player
	events         chan playerEvent
	timer          *time.Timer
	timerKind      string
	output         *json.Encoder
	logs           io.Writer
	writeErr       error
	dvrTicker      *time.Ticker
	recorder       *recording.Manager
	recordingPath  string
	recordingStart float64
	lastCheckpoint time.Time
	sleepDeadline  time.Time
	sleepTicker    *time.Ticker
}

func Run(ctx context.Context, cfg Config, input io.Reader, output, logs io.Writer) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	useCustom := !cfg.DisableCustomStations && (cfg.StationFile == "" || cfg.CustomStationFile != "")
	useRecordings := !cfg.DisableRecordings && (cfg.StationFile == "" || cfg.RecordingConfig != nil)
	if err := cfg.defaults(); err != nil {
		return err
	}
	bundled, err := LoadStations(cfg.StationFile)
	if err != nil {
		return err
	}
	stations := bundled
	var custom []CustomStation
	var customErr error
	customPath := ""
	if useCustom {
		customPath = cfg.CustomStationFile
		if customPath == "" {
			customPath, customErr = CustomStationPath()
		}
		if customErr == nil {
			custom, customErr = LoadCustomStations(customPath, bundled)
		}
		if customErr == nil {
			stations = MergeCustomStations(bundled, custom)
		}
	}
	dir, lock, err := acquireRuntime(cfg.RuntimeBase)
	if err != nil {
		return err
	}
	defer lock.Close()
	r := &controller{cfg: cfg, stations: stations, bundled: bundled, custom: custom, customPath: customPath, customLoadErr: customErr, socket: filepath.Join(dir, "mpv.sock"), events: make(chan playerEvent, 64), output: json.NewEncoder(output), logs: logs,
		state: Status{State: "stopped", PlaybackKind: "live", PlaybackSpeed: 1, Volume: 65, Station: Station{}, Stations: stations, BufferMinutes: int(cfg.DVRWindow / time.Minute)}}
	if customErr != nil {
		r.state.CustomStationError = "Unable to load custom stations; repair the file and restart Yakker."
	}
	defer r.cleanup()
	defer r.cancelSleep()
	defer r.clearTimer()
	if useRecordings {
		r.openRecorder()
		if r.recorder != nil {
			defer func() { r.stop(); _ = r.recorder.Close() }()
		}
	}
	lines := make(chan inputLine)
	done := make(chan struct{})
	defer close(done)
	go func() {
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 4096), 65536)
		for scanner.Scan() {
			line := inputLine{data: append([]byte(nil), scanner.Bytes()...)}
			select {
			case lines <- line:
			case <-done:
				return
			}
		}
		select {
		case lines <- inputLine{err: scanner.Err(), eof: true}:
		case <-done:
		}
		close(lines)
	}()
	if err := r.publish(); err != nil {
		return err
	}
	for {
		if r.writeErr != nil {
			return r.writeErr
		}
		var timer <-chan time.Time
		if r.timer != nil {
			timer = r.timer.C
		}
		var dvrTick <-chan time.Time
		if r.dvrTicker != nil {
			dvrTick = r.dvrTicker.C
		}
		var sleepTick <-chan time.Time
		if r.sleepTicker != nil {
			sleepTick = r.sleepTicker.C
		}
		var recordingUpdates <-chan struct{}
		if r.recorder != nil {
			recordingUpdates = r.recorder.Updates()
		}
		var exited <-chan struct{}
		if r.player != nil && r.player.conn == nil {
			// Once connected, consume socket events in order, including end-file stop
			// before EOF, rather than racing process exit against an intentional Stop.
			exited = r.player.done
		}
		select {
		case <-ctx.Done():
			return nil
		case line, ok := <-lines:
			if !ok || line.eof {
				return line.err
			}
			quit, err := r.command(line.data)
			if err != nil {
				r.state.Error = head(err.Error(), 240)
			}
			if err := r.publish(); err != nil {
				return err
			}
			if quit {
				return nil
			}
		case <-sleepTick:
			r.updateSleep()
			_ = r.publish()
		case <-dvrTick:
			if r.state.PlaybackKind == "recording" {
				r.state.Position = r.currentPosition()
				r.checkpoint(false, false)
				_ = r.publish()
			} else {
				r.updateDVR()
			}
		case <-recordingUpdates:
			r.refreshRecordings()
			_ = r.publish()
		case <-exited:
			r.fail(r.player.logs.message("The player disconnected"))
		case event := <-r.events:
			if event.source != r.player {
				continue
			}
			if event.err != nil {
				r.fail(r.player.logs.message("The player disconnected"))
				continue
			}
			r.event(event.value)
		case <-timer:
			kind := r.timerKind
			r.clearTimer()
			switch kind {
			case "retry":
				r.start()
			case "socket":
				r.connect()
			case "deadline":
				if remaining := r.watchdogRemaining(); remaining > 0 {
					r.after("deadline", remaining)
				} else {
					r.fail("The stream timed out. Check your connection.")
				}
			}
		}
	}
}

func (r *controller) publish() error {
	if r.writeErr == nil {
		r.writeErr = r.output.Encode(r.state)
	}
	return r.writeErr
}
func (r *controller) clearTimer() {
	if r.timer != nil {
		r.timer.Stop()
	}
	r.timer = nil
	r.timerKind = ""
}
func (r *controller) after(kind string, delay time.Duration) {
	// Go 1.26's channel-timer Reset discards stale notifications. The event
	// loop is the sole owner, so a heartbeat can refresh the existing deadline
	// without allocating a timer or scheduling an extra goroutine.
	if r.timer == nil {
		r.timer = time.NewTimer(delay)
	} else {
		r.timer.Reset(delay)
	}
	r.timerKind = kind
}

func (r *controller) command(raw []byte) (bool, error) {
	var data map[string]json.RawMessage
	if err := json.Unmarshal(raw, &data); err != nil {
		return false, err
	}
	if data == nil {
		return false, errors.New("Command must be an object")
	}
	if serial, ok := data["serial"]; ok {
		var number int64
		if string(serial) == "null" || json.Unmarshal(serial, &number) != nil {
			return false, errors.New("Command serial must be an integer")
		}
		r.state.Serial = number
	}
	var action string
	_ = json.Unmarshal(data["action"], &action)
	switch action {
	case "previewSchedule":
		r.previewScheduleCommand(data)
	case "startRecording", "recordingSettings", "upsertSchedule", "deleteSchedule", "stopRecording", "deleteRecording":
		r.recordingCommand(action, data)
	case "playRecording":
		return false, r.playRecordingCommand(data)
	case "speed":
		return false, r.speedCommand(data)
	case "sleepTimer":
		return false, r.sleepCommand(data)
	case "seekRecording":
		return false, r.seekRecordingCommand(data)
	case "upsertStation", "deleteStation":
		r.updateCustomStation(action, data)
	case "configure":
		window := r.cfg.DVRWindow
		if raw, ok := data["bufferMinutes"]; ok {
			var minutes int
			if string(raw) == "null" || json.Unmarshal(raw, &minutes) != nil || (minutes != 0 && minutes != 5 && minutes != 15 && minutes != 30) {
				return false, errors.New("Buffer must be 0, 5, 15 or 30 minutes")
			}
			window = time.Duration(minutes) * time.Minute
		}
		var plugin string
		if raw, ok := data["mprisPlugin"]; ok {
			if string(raw) == "null" || json.Unmarshal(raw, &plugin) != nil {
				return false, errors.New("MPRIS plugin path does not exist")
			}
		}
		if plugin != "" {
			info, err := os.Stat(plugin)
			if err != nil || !info.Mode().IsRegular() {
				return false, errors.New("MPRIS plugin path does not exist")
			}
		}
		station := r.state.Station
		if raw, ok := data["stationId"]; ok {
			var id string
			if string(raw) == "null" || json.Unmarshal(raw, &id) != nil {
				return false, errors.New("Station ID must be a string")
			}
			station = Station{}
			for _, s := range r.stations {
				if s["id"] == id {
					station = s
					break
				}
			}
		}
		// Station IDs are unique across the current merged catalogue.
		bufferChanged := window != r.cfg.DVRWindow
		stationChanged := station["id"] != r.state.Station["id"]
		switchToLive := stationChanged && len(station) != 0
		changed := (stationChanged && (r.state.PlaybackKind != "recording" || switchToLive)) || plugin != r.mpris || (bufferChanged && r.state.PlaybackKind != "recording")
		r.cfg.DVRWindow = window
		if bufferChanged {
			r.cfg.DVRBytes = dvrByteLimit(window)
		}
		r.state.BufferMinutes = int(window / time.Minute)
		r.state.Station = station
		r.mpris = plugin
		r.state.MPRIS = plugin != ""
		if changed {
			wanted, paused := r.state.Wanted, r.state.Paused && !bufferChanged && !r.state.TemporaryBuffer
			wasRecording := r.state.PlaybackKind == "recording"
			r.stop()
			if stationChanged && (!wasRecording || switchToLive) {
				r.selectLivePlayback()
			}
			if wanted && (wasRecording || len(station) != 0) {
				r.state.Paused = paused
				if wasRecording && !switchToLive {
					r.startRecordingPlayback()
				} else {
					r.play()
				}
			}
		}
	case "play":
		if r.state.Wanted {
			return false, r.setPaused(false)
		}
		if len(r.state.Station) == 0 {
			return false, errors.New("Choose a station before playing live radio.")
		}
		r.selectLivePlayback()
		r.play()
	case "pause":
		return false, r.setPaused(true)
	case "seek", "skip":
		var value float64
		raw := data["value"]
		if len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &value) != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return false, errors.New("Seek must be a finite number of seconds")
		}
		if action == "skip" {
			value += r.currentPosition()
		}
		if r.state.PlaybackKind == "recording" {
			return false, r.seekFile(value)
		}
		return false, r.seekDVR(value)
	case "live":
		if len(r.state.Station) == 0 {
			if !r.state.Wanted {
				r.selectLivePlayback()
			}
			return false, errors.New("Choose a station before playing live radio.")
		}
		if r.state.PlaybackKind == "recording" {
			r.stop()
			r.selectLivePlayback()
			r.play()
			return false, nil
		}
		if !r.state.Wanted {
			r.play()
			return false, nil
		}
		if r.state.DVR && r.player != nil {
			r.player.cacheMu.Lock()
			liveEnd := r.player.cache.end
			r.player.cacheMu.Unlock()
			if err := r.seekDVR(liveEnd - 1); err != nil {
				return false, err
			}
		}
		return false, r.setPaused(false)
	case "stop":
		r.cancelSleep()
		r.stop()
	case "volume":
		var value float64
		if raw := data["value"]; len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &value) != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return false, errors.New("Volume must be a finite number")
		}
		r.state.Volume = int(math.Max(0, math.Min(100, math.RoundToEven(value))))
		if r.player != nil && r.player.conn != nil {
			volume := r.state.Volume
			r.player.pendingVolume = &volume
		}
		return false, r.ipc([]any{"set_property", "volume", r.state.Volume})
	case "mute":
		var value bool
		if raw := data["value"]; len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &value) != nil {
			return false, errors.New("Mute must be a boolean")
		}
		r.state.Muted = value
		if r.player != nil && r.player.conn != nil {
			r.player.pendingMute = &value
		}
		return false, r.ipc([]any{"set_property", "mute", value})
	case "quit":
		r.stop()
		return true, nil
	case "status":
	default:
		return false, errors.New("Unknown radio command")
	}
	return false, nil
}

func (r *controller) play() {
	if r.state.Wanted {
		_ = r.setPaused(false)
		return
	}
	r.state.Wanted = true
	r.state.Retry = 0
	r.state.RetryDelay = 0
	r.state.Error = ""
	r.state.Title = ""
	r.start()
}
func (r *controller) stop() {
	r.stopWithCompletion(false)
}
func (r *controller) stopWithCompletion(completed bool) {
	r.checkpoint(true, completed)
	if completed && r.player != nil {
		r.player.position.Store(0)
	}
	r.state.Wanted = false
	r.state.Paused = false
	r.state.TemporaryBuffer = false
	r.clearTimer()
	r.cleanup()
	r.state.State = "stopped"
	r.state.Error = ""
	r.state.Title = ""
	r.state.Retry = 0
	r.state.RetryDelay = 0
}
func (r *controller) cleanup() {
	if r.dvrTicker != nil {
		r.dvrTicker.Stop()
		r.dvrTicker = nil
	}
	r.state.DVR = false
	r.state.Position, r.state.BufferStart, r.state.BufferEnd = 0, 0, 0
	r.state.BufferExpired = false
	p := r.player
	if p == nil {
		return
	}
	r.player = nil
	close(p.closed)
	if p.conn != nil {
		p.conn.Close()
	}
	_ = p.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-p.done:
	case <-time.After(2 * time.Second):
		_ = p.cmd.Process.Kill()
		<-p.done
	}
	r.state.PlayerPID = 0
	_ = os.Remove(r.socket)
}
func (r *controller) start() {
	r.clearTimer()
	r.state.State = "connecting"
	r.state.Title = ""
	_ = os.Remove(r.socket) // The exclusive owner lock is held.
	args := append([]string{}, r.cfg.MPVArgs...)
	// mpv fixes demuxer limits when opening the stream. Reserve enough RAM
	// for pause in live-only mode without exposing prior audio as DVR history.
	window := r.effectiveWindow()
	bytes := r.effectiveBytes()
	if window == 0 {
		window = temporaryWindow
		bytes = dvrByteLimit(window)
	}
	cacheSeconds := window.Seconds() + 10
	backBytes := bytes
	var input, title string
	cacheEnabled := "yes"
	if r.state.PlaybackKind == "recording" {
		input, title, cacheEnabled = r.recordingPath, r.state.RecordingTitle, "no"
		// File decoding still needs a forward packet queue even with cache=no.
		cacheSeconds, bytes, backBytes = 3, 2*1024*1024, 0
	} else {
		input, title = r.state.Station["streamUrl"].(string), r.state.Station["name"].(string)
	}
	args = append(args, "--no-config", "--load-scripts=no", "--no-video", "--no-audio-display", "--idle=no", "--terminal=no", "--input-terminal=no", "--keep-open=no",
		"--cache="+cacheEnabled, fmt.Sprintf("--cache-secs=%g", cacheSeconds), fmt.Sprintf("--demuxer-max-bytes=%d", bytes), fmt.Sprintf("--demuxer-max-back-bytes=%d", backBytes), "--demuxer-donate-buffer=no", "--demuxer-seekable-cache=yes", "--cache-on-disk=no", "--network-timeout=15", "--msg-level=all=warn",
		"--input-ipc-server="+r.socket, fmt.Sprintf("--volume=%d", r.state.Volume), "--mute="+map[bool]string{true: "yes", false: "no"}[r.state.Muted], "--force-media-title="+title)
	if r.state.PlaybackKind == "recording" {
		args = append(args, fmt.Sprintf("--start=%g", r.recordingStart), fmt.Sprintf("--speed=%g", r.state.PlaybackSpeed), "--audio-pitch-correction=yes")
	}
	if r.mpris != "" {
		args = append(args, "--script="+r.mpris)
	}
	args = append(args, "--", input)
	cmd := exec.Command(r.cfg.MPV, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	logs := &playerLog{output: r.logs, private: r.state.Station["custom"] == true || r.state.Station["id"] == "cli"}
	cmd.Stderr = logs
	if err := cmd.Start(); err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			r.state.State = "error"
			r.state.Error = "mpv is missing. Install the mpv package, then retry."
			r.state.Wanted = false
			_ = r.publish()
			return
		}
		r.fail(err.Error())
		return
	}
	p := &player{cmd: cmd, done: make(chan struct{}), closed: make(chan struct{}), logs: logs, started: time.Now(), socketDeadline: time.Now().Add(5 * time.Second)}
	p.position.Store(math.Float64bits(r.recordingStart))
	r.player = p
	r.state.PlayerPID = cmd.Process.Pid
	go func() { _ = cmd.Wait(); close(p.done) }()
	_ = r.publish()
	r.connect()
}
func (r *controller) connect() {
	p := r.player
	conn, err := net.DialTimeout("unix", r.socket, 50*time.Millisecond)
	if err != nil {
		if time.Now().After(p.socketDeadline) {
			r.fail("mpv did not open its control socket")
			return
		}
		r.after("socket", 50*time.Millisecond)
		return
	}
	p.conn = conn
	pause := r.state.Paused
	p.pendingPause = &pause
	// Controls may change while waiting for mpv to open the socket. Apply the
	// latest preferences before observing initial player values.
	for _, command := range [][]any{{"set_property", "volume", r.state.Volume}, {"set_property", "mute", r.state.Muted}, {"set_property", "pause", r.state.Paused}} {
		if err := r.ipc(command); err != nil {
			r.fail(err.Error())
			return
		}
	}
	if r.state.PlaybackKind == "recording" {
		if err := r.ipc([]any{"set_property", "speed", r.state.PlaybackSpeed}); err != nil {
			r.fail(err.Error())
			return
		}
	}
	observed := []string{"volume", "mute", "metadata", "core-idle", "pause", "time-pos"}
	if r.state.PlaybackKind == "recording" {
		observed = append(observed, "duration")
	} else if r.effectiveWindow() > 0 {
		observed = append(observed, "demuxer-cache-state")
	}
	for i, name := range observed {
		if err := r.ipc([]any{"observe_property", i + 1, name}); err != nil {
			r.fail(err.Error())
			return
		}
	}
	r.after("deadline", r.cfg.ConnectTimeout)
	if r.state.PlaybackKind == "recording" {
		r.fileTicker()
	} else if r.effectiveWindow() > 0 {
		r.dvrTicker = time.NewTicker(r.cfg.DVRPollInterval)
	}
	go func() {
		scanner := bufio.NewScanner(conn)
		scanner.Buffer(make([]byte, 4096), 1024*1024)
		deliver := func(e playerEvent) bool {
			select {
			case r.events <- e:
				return true
			case <-p.closed:
				return false
			}
		}
		for scanner.Scan() {
			var event mpvEvent
			if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
				deliver(playerEvent{source: p, err: err})
				return
			}
			if p.consumeProgress(event) || p.consumeCache(event) {
				continue
			}
			if !deliver(playerEvent{source: p, value: event}) {
				return
			}
		}
		deliver(playerEvent{source: p, err: io.EOF})
	}()
}
func (r *controller) ipc(command []any) error {
	if r.player == nil || r.player.conn == nil {
		return nil
	}
	conn := r.player.conn
	if err := conn.SetWriteDeadline(time.Now().Add(2 * time.Second)); err != nil {
		return err
	}
	return json.NewEncoder(conn).Encode(map[string]any{"command": command})
}
func (r *controller) fail(message string) {
	if r.player != nil && time.Since(r.player.started) > r.cfg.ResetAfter && (r.state.State == "playing" || r.state.State == "paused") {
		r.state.Retry = 0
	}
	r.checkpoint(true, false)
	r.cleanup()
	r.clearTimer()
	if !r.state.Wanted {
		return
	}
	r.state.Error = head(message, 240)
	if r.state.PlaybackKind == "recording" || r.state.Retry >= len(r.cfg.RetryDelays) {
		r.state.Wanted = false
		r.state.Paused = false
		r.state.TemporaryBuffer = false
		r.state.State = "error"
		r.state.RetryDelay = 0
	} else {
		delay := r.cfg.RetryDelays[r.state.Retry]
		r.state.Retry++
		r.state.RetryDelay = delay.Seconds()
		r.state.State = "retrying"
		r.after("retry", delay)
	}
	_ = r.publish()
}

// Progress is a watchdog heartbeat, not a UI event. Record it in the socket
// reader without waking the controller's locked OS thread for every packet.
// Relative monotonic time avoids wall-clock adjustments and keeps old-player
// progress isolated in the player that produced it.
func (p *player) consumeProgress(event mpvEvent) bool {
	if event.Event != "property-change" || event.Name != "time-pos" {
		return false
	}
	if value, ok := event.Data.(float64); ok && !math.IsNaN(value) && !math.IsInf(value, 0) {
		p.position.Store(math.Float64bits(value))
		p.lastProgress.Store(time.Since(p.started).Nanoseconds())
	}
	return true
}

func (r *controller) watchdogRemaining() time.Duration {
	p := r.player
	if p == nil || (r.state.State != "playing" && r.state.State != "paused") {
		return 0
	}
	if r.pausedFile() {
		return r.cfg.StallTimeout
	}
	last := max(time.Duration(p.lastProgress.Load()), p.playbackSince)
	if r.state.Paused {
		last = max(time.Duration(p.lastIntake.Load()), p.playbackSince)
	}
	return r.cfg.StallTimeout - (time.Since(p.started) - last)
}

// Only these public properties can change in ordinary mpv property events.
// Stop/end-file paths publish explicitly; station, serial and retry-count
// changes belong to command/supervisor handling. The snapshot is comparable
// without reflection or heap allocation.
type playbackProperties struct {
	state, error, title string
	volume              int
	muted               bool
	retryDelay          float64
	duration            float64
}

func (r *controller) properties() playbackProperties {
	s := &r.state
	return playbackProperties{s.State, s.Error, s.Title, s.Volume, s.Muted, s.RetryDelay, s.Duration}
}

func (r *controller) event(event mpvEvent) {

	before := r.properties()
	kind, name, value := event.Event, event.Name, event.Data
	if kind == "end-file" {
		reason := event.Reason
		if reason == "stop" || (r.state.PlaybackKind == "recording" && reason == "eof") {
			r.stopWithCompletion(reason == "eof")
			_ = r.publish()
			return
		}
		message := event.FileError
		if message == "" {
			message = reason
		}
		if message == "" {
			message = "ended"
		}
		r.fail("Stream unavailable: " + message)
		return
	}
	if kind == "playback-restart" || (kind == "property-change" && name == "core-idle" && value == false) {
		r.state.State = "playing"
		if r.state.Paused {
			r.state.State = "paused"
		}
		r.state.Error = ""
		r.state.RetryDelay = 0
		if r.player != nil {
			r.player.playbackSince = time.Since(r.player.started)
		}
		r.after("deadline", r.cfg.StallTimeout)
	}
	if kind == "property-change" {
		switch name {
		case "duration":
			r.fileDuration(value)
		case "core-idle":
			if value == true && r.state.State == "playing" && !r.state.Paused {
				r.state.State = "connecting"
				r.after("deadline", r.cfg.StallTimeout)
			}
		case "volume":
			if v, ok := value.(float64); ok {
				volume := int(math.Max(0, math.Min(100, math.RoundToEven(v))))
				if r.player != nil && r.player.pendingVolume != nil {
					if volume != *r.player.pendingVolume {
						break
					}
					r.player.pendingVolume = nil
				}
				r.state.Volume = volume
			}
		case "mute":
			if v, ok := value.(bool); ok {
				if r.player != nil && r.player.pendingMute != nil {
					if v != *r.player.pendingMute {
						break
					}
					r.player.pendingMute = nil
				}
				r.state.Muted = v
			}
		case "pause":
			if paused, ok := value.(bool); ok && r.state.Wanted {
				if r.player != nil && r.player.pendingPause != nil {
					if paused != *r.player.pendingPause {
						break
					}
					r.player.pendingPause = nil
				}
				if paused && r.effectiveWindow() == 0 && r.state.PlaybackKind != "recording" {
					if err := r.enableTemporaryBuffer(); err != nil {
						r.fail(err.Error())
						return
					}
				}
				if paused == r.state.Paused {
					break
				}
				r.state.Paused = paused
				if paused {
					r.checkpoint(true, false)
				}
				if paused {
					r.state.State = "paused"
				} else if r.state.State == "paused" {
					r.state.State = "playing"
				}
				if r.player != nil {
					r.player.playbackSince = time.Since(r.player.started)
				}
				r.after("deadline", r.cfg.StallTimeout)
				_ = r.publish()
			}
		case "metadata":
			if metadata, ok := value.(map[string]any); ok {
				title, _ := metadata["icy-title"].(string)
				if title == "" {
					title, _ = metadata["title"].(string)
				}
				r.state.Title = head(title, 180)
			}
		}
	}
	if before != r.properties() {
		_ = r.publish()
	}
}
func head(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
func tail(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[len(r)-n:])
}
