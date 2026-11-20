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
)

type Station map[string]any

type Status struct {
	State      string  `json:"state"`
	Wanted     bool    `json:"wanted"`
	Error      string  `json:"error"`
	Volume     int     `json:"volume"`
	Muted      bool    `json:"muted"`
	Title      string  `json:"title"`
	Station    Station `json:"station"`
	Retry      int     `json:"retry"`
	RetryDelay float64 `json:"retryDelay"`
	PlayerPID  int     `json:"playerPid"`
	MPRIS      bool    `json:"mpris"`
	Serial     int64   `json:"serial"`
}

// Config overrides are used by the standalone CLI and tests; normal plugin
// startup uses the executable's adjacent stations.json and the real mpv.
type Config struct {
	RuntimeBase    string
	StationFile    string
	MPV            string
	MPVArgs        []string
	ConnectTimeout time.Duration
	StallTimeout   time.Duration
	RetryDelays    []time.Duration
	ResetAfter     time.Duration
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
	if c.RetryDelays == nil {
		c.RetryDelays = []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second}
	}
	return nil
}

type player struct {
	lastProgress   atomic.Int64
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
	last   string
	output io.Writer
}

func (l *playerLog) Write(data []byte) (int, error) {
	l.Lock()
	defer l.Unlock()
	message := strings.TrimSpace(string(data))
	if message != "" {
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
	cfg       Config
	state     Status
	stations  []Station
	socket    string
	mpris     string
	player    *player
	events    chan playerEvent
	timer     *time.Timer
	timerKind string
	output    *json.Encoder
	logs      io.Writer
	writeErr  error
}

func Run(ctx context.Context, cfg Config, input io.Reader, output, logs io.Writer) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := cfg.defaults(); err != nil {
		return err
	}
	stations, err := LoadStations(cfg.StationFile)
	if err != nil {
		return err
	}
	dir, lock, err := acquireRuntime(cfg.RuntimeBase)
	if err != nil {
		return err
	}
	defer lock.Close()
	r := &controller{cfg: cfg, stations: stations, socket: filepath.Join(dir, "mpv.sock"), events: make(chan playerEvent, 64), output: json.NewEncoder(output), logs: logs,
		state: Status{State: "stopped", Volume: 65, Station: stations[0]}}
	defer r.cleanup()
	defer r.clearTimer()
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
	case "configure":
		var id, plugin string
		_ = json.Unmarshal(data["stationId"], &id)
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
		station := r.stations[0]
		for _, s := range r.stations {
			if s["id"] == id {
				station = s
				break
			}
		}
		// Station IDs are unique and records are immutable after startup.
		changed := station["id"] != r.state.Station["id"] || plugin != r.mpris
		r.state.Station = station
		r.mpris = plugin
		r.state.MPRIS = plugin != ""
		if changed {
			wanted := r.state.Wanted
			r.stop()
			if wanted {
				r.play()
			}
		}
	case "play":
		r.play()
	case "stop":
		r.stop()
	case "volume":
		var value float64
		if raw := data["value"]; len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &value) != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return false, errors.New("Volume must be a finite number")
		}
		r.state.Volume = int(math.Max(0, math.Min(100, math.RoundToEven(value))))
		return false, r.ipc([]any{"set_property", "volume", r.state.Volume})
	case "mute":
		var value bool
		if raw := data["value"]; len(raw) == 0 || string(raw) == "null" || json.Unmarshal(raw, &value) != nil {
			return false, errors.New("Mute must be a boolean")
		}
		r.state.Muted = value
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
	r.state.Wanted = false
	r.clearTimer()
	r.cleanup()
	r.state.State = "stopped"
	r.state.Error = ""
	r.state.Title = ""
	r.state.Retry = 0
	r.state.RetryDelay = 0
}
func (r *controller) cleanup() {
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
	args = append(args, "--no-config", "--load-scripts=no", "--no-video", "--no-audio-display", "--idle=no", "--terminal=no", "--input-terminal=no", "--keep-open=no",
		"--cache=yes", "--cache-secs=3", "--demuxer-max-bytes=2MiB", "--demuxer-max-back-bytes=0", "--network-timeout=15", "--msg-level=all=warn",
		"--input-ipc-server="+r.socket, fmt.Sprintf("--volume=%d", r.state.Volume), "--mute="+map[bool]string{true: "yes", false: "no"}[r.state.Muted], "--force-media-title="+r.state.Station["name"].(string))
	if r.mpris != "" {
		args = append(args, "--script="+r.mpris)
	}
	args = append(args, "--", r.state.Station["streamUrl"].(string))
	cmd := exec.Command(r.cfg.MPV, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGTERM}
	logs := &playerLog{output: r.logs}
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
	// Controls may change while waiting for mpv to open the socket. Apply the
	// latest preferences before observing initial player values.
	for _, command := range [][]any{{"set_property", "volume", r.state.Volume}, {"set_property", "mute", r.state.Muted}} {
		if err := r.ipc(command); err != nil {
			r.fail(err.Error())
			return
		}
	}
	for i, name := range []string{"volume", "mute", "metadata", "core-idle", "pause", "time-pos"} {
		if err := r.ipc([]any{"observe_property", i + 1, name}); err != nil {
			r.fail(err.Error())
			return
		}
	}
	r.after("deadline", r.cfg.ConnectTimeout)
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
			if p.consumeProgress(event) {
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
	if r.player != nil && time.Since(r.player.started) > r.cfg.ResetAfter && r.state.State == "playing" {
		r.state.Retry = 0
	}
	r.cleanup()
	r.clearTimer()
	if !r.state.Wanted {
		return
	}
	r.state.Error = head(message, 240)
	if r.state.Retry >= len(r.cfg.RetryDelays) {
		r.state.Wanted = false
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
	if _, ok := event.Data.(float64); ok {
		p.lastProgress.Store(time.Since(p.started).Nanoseconds())
	}
	return true
}

func (r *controller) watchdogRemaining() time.Duration {
	p := r.player
	if p == nil || r.state.State != "playing" {
		return 0
	}
	last := max(time.Duration(p.lastProgress.Load()), p.playbackSince)
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
}

func (r *controller) properties() playbackProperties {
	s := &r.state
	return playbackProperties{s.State, s.Error, s.Title, s.Volume, s.Muted, s.RetryDelay}
}

func (r *controller) event(event mpvEvent) {

	before := r.properties()
	kind, name, value := event.Event, event.Name, event.Data
	if kind == "end-file" {
		reason := event.Reason
		if reason == "stop" {
			r.stop()
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
		r.state.Error = ""
		r.state.RetryDelay = 0
		if r.player != nil {
			r.player.playbackSince = time.Since(r.player.started)
		}
		r.after("deadline", r.cfg.StallTimeout)
	}
	if kind == "property-change" {
		switch name {
		case "core-idle":
			if value == true && r.state.State == "playing" {
				r.state.State = "connecting"
				r.after("deadline", r.cfg.StallTimeout)
			}
		case "volume":
			if v, ok := value.(float64); ok {
				r.state.Volume = int(math.Max(0, math.Min(100, math.RoundToEven(v))))
			}
		case "mute":
			if v, ok := value.(bool); ok {
				r.state.Muted = v
			}
		case "pause":
			if value == true {
				r.stop()
				_ = r.publish()
				return
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
