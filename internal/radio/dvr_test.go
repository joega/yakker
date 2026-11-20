package radio

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"math"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestDVRDefaultsAndInputValidation(t *testing.T) {
	cfg := Config{}
	if err := cfg.defaults(); err != nil {
		t.Fatal(err)
	}
	if cfg.DVRWindow != 0 || cfg.DVRBytes != 2*1024*1024 {
		t.Fatal("Live only must remain the default", cfg)
	}
	r := &controller{cfg: cfg, stations: []Station{{"id": "fixture"}}, state: Status{Station: Station{"id": "fixture"}}}
	for _, raw := range []string{`{"action":"configure","bufferMinutes":null}`, `{"action":"configure","bufferMinutes":-1}`, `{"action":"configure","bufferMinutes":60}`, `{"action":"configure","bufferMinutes":5.5}`, `{"action":"seek","value":null}`, `{"action":"skip","value":"NaN"}`} {
		if _, err := r.command([]byte(raw)); err == nil {
			t.Fatal("accepted invalid DVR input", raw)
		}
		if r.cfg.DVRWindow != 0 || r.state.Wanted {
			t.Fatal("invalid input changed playback")
		}
	}
	if err := r.setPaused(true); err == nil {
		t.Fatal("stopped playback allowed a pause")
	}
}
func TestDVRPreferenceChangesDoNotAutoplay(t *testing.T) {
	cfg := Config{}
	if err := cfg.defaults(); err != nil {
		t.Fatal(err)
	}
	r := &controller{cfg: cfg, stations: []Station{{"id": "fixture"}}, state: Status{State: "stopped", Station: Station{"id": "fixture"}}}
	for _, minutes := range []int{5, 15, 30, 0} {
		raw, _ := json.Marshal(map[string]any{"action": "configure", "stationId": "fixture", "bufferMinutes": minutes})
		if _, err := r.command(raw); err != nil {
			t.Fatal(err)
		}
		if r.state.Wanted || r.player != nil || r.state.DVR || r.state.BufferMinutes != minutes || r.cfg.DVRBytes != dvrByteLimit(time.Duration(minutes)*time.Minute) {
			t.Fatal("buffer preference started playback or used wrong cap", r.state)
		}
	}
}

func TestDVRSeekClampsToRetainedRange(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	commands := make(chan []any, 8)
	go func() {
		decoder := json.NewDecoder(server)
		for {
			var message struct {
				Command []any `json:"command"`
			}
			if decoder.Decode(&message) != nil {
				return
			}
			commands <- message.Command
		}
	}()
	r := &controller{state: Status{Wanted: true, DVR: true, BufferStart: 100, BufferEnd: 200}, cfg: Config{DVRWindow: 30 * time.Minute}, player: &player{conn: client, cache: cacheWindow{start: 100, end: 200, valid: true}}}
	for _, tc := range []struct{ target, want float64 }{{-100, 100}, {150, 150}, {500, 199.75}} {
		if err := r.seekDVR(tc.target); err != nil {
			t.Fatal(err)
		}
		cmd := <-commands
		if cmd[0] != "seek" || cmd[1] != tc.want || cmd[2] != "absolute+exact" {
			t.Fatal(cmd)
		}
	}
	for _, value := range []float64{math.NaN(), math.Inf(1)} {
		if r.seekDVR(value) == nil {
			t.Fatal("accepted non-finite seek")
		}
	}
}
func TestDVRCacheBoundsAndPausedWatchdog(t *testing.T) {
	p := &player{started: time.Now().Add(-10 * time.Second)}
	p.consumeCache(mpvEvent{Event: "property-change", Name: "demuxer-cache-state", Data: map[string]any{"seekable-ranges": []any{map[string]any{"start": 0.0, "end": 100.0}, map[string]any{"start": 200.0, "end": 210.0}, map[string]any{"start": math.NaN(), "end": 500.0}}}})
	if !p.cache.valid || p.cache.start != 200 || p.cache.end != 210 {
		t.Fatal(p.cache)
	}
	r := &controller{player: p, cfg: Config{StallTimeout: 30 * time.Second}, state: Status{State: "paused", Paused: true}}
	if r.watchdogRemaining() < 29*time.Second {
		t.Fatal("fresh intake did not keep paused stream alive")
	}
}

func TestTemporaryBufferReconnectAndStationSwitch(t *testing.T) {
	path := filepath.Join(tempDir(t), "stations.json")
	data, _ := json.Marshal([]Station{
		{"id": "one", "name": "One", "subtitle": "Test", "streamUrl": "http://localhost/one"},
		{"id": "two", "name": "Two", "subtitle": "Test", "streamUrl": "http://localhost/two"},
	})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, Config{StationFile: path, RetryDelays: []time.Duration{20 * time.Millisecond}}, false)
	first := h.play()
	h.send("pause")
	paused := h.wait(func(s Status) bool { return s.Paused && s.TemporaryBuffer })
	if paused.PlayerPID != first.PlayerPID || paused.BufferMinutes != 0 {
		t.Fatal(paused)
	}
	if err := syscall.Kill(paused.PlayerPID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	retry := h.wait(func(s Status) bool { return s.State == "paused" && s.PlayerPID != 0 && s.PlayerPID != first.PlayerPID })
	if !retry.TemporaryBuffer || retry.BufferMinutes != 0 || retry.DVR || retry.BufferStart != 0 {
		t.Fatal("reconnect did not start a fresh temporary cache", retry)
	}
	serial := h.send("configure", "stationId", "two", "bufferMinutes", 0)
	switched := h.wait(func(s Status) bool { return s.Serial == serial && s.Station["id"] == "two" && s.State == "playing" })
	if switched.TemporaryBuffer || switched.Paused || switched.DVR || switched.BufferMinutes != 0 {
		t.Fatal("station switch retained temporary cache", switched)
	}
}

// A paced, endless local PCM stream verifies real mpv's native seek cache without
// broadcaster access, additional tools, disk recording, or acoustic output.
func TestRealMPVDVRPauseSeekLiveExpireAndOptOut(t *testing.T) {
	if os.Getenv("YAKKER_TEST_REAL_MPV") != "1" {
		t.Skip("set YAKKER_TEST_REAL_MPV=1 for real-mpv DVR integration")
	}
	mpv, err := exec.LookPath("mpv")
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		requests.Add(1)
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
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-req.Context().Done():
				return
			case <-ticker.C:
				if _, err := w.Write(make([]byte, 44100*4/10)); err != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}))
	t.Cleanup(server.Close)
	path := filepath.Join(tempDir(t), "stations.json")
	data, _ := json.Marshal([]Station{{"id": "fixture", "name": "Local DVR fixture", "subtitle": "Test", "streamUrl": server.URL + "/live.wav"}})
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, Config{StationFile: path, MPV: mpv, MPVArgs: []string{"--ao=null"}, DVRWindow: 8 * time.Second, DVRPollInterval: 100 * time.Millisecond}, false)
	first := h.play()
	ready := h.wait(func(s Status) bool { return s.DVR && s.Position > 1 && s.BufferEnd > 2 })
	h.send("pause")
	paused := h.wait(func(s Status) bool { return s.State == "paused" && s.Paused && s.DVR })
	later := h.wait(func(s Status) bool { return s.Paused && s.BufferEnd > paused.BufferEnd+1 })
	if math.Abs(later.Position-paused.Position) > .3 {
		t.Fatal("paused playback moved before expiration", ready, paused, later)
	}
	expired := h.wait(func(s Status) bool { return s.Paused && s.BufferExpired && s.BufferStart > paused.Position+.5 })
	if expired.BufferEnd-expired.BufferStart > 8.1 || expired.PlayerPID != first.PlayerPID {
		t.Fatal("rolling expiration lost the player or window", expired)
	}
	h.send("play")
	resumed := h.wait(func(s Status) bool { return s.State == "playing" && !s.Paused && s.Position > expired.Position+.2 })
	if resumed.PlayerPID != first.PlayerPID {
		t.Fatal("resume reconnected instead of using buffer")
	}
	h.send("live")
	live := h.wait(func(s Status) bool { return !s.Paused && s.DVR && s.BufferEnd-s.Position < 2 })
	if live.PlayerPID != first.PlayerPID {
		t.Fatal("Go live replaced player")
	}
	h.send("skip", "value", -2)
	rewound := h.wait(func(s Status) bool { return s.Position < live.Position-1 })
	if rewound.PlayerPID != first.PlayerPID {
		t.Fatal("seek replaced player")
	}
	h.send("live")
	h.wait(func(s Status) bool { return s.DVR && s.BufferEnd-s.Position < 2 })
	if requests.Load() != 1 {
		t.Fatal("cached seeking made a network request", requests.Load())
	}
	serial := h.send("configure", "stationId", "fixture", "bufferMinutes", 0)
	clear := h.wait(func(s Status) bool {
		return s.Serial == serial && s.State == "playing" && s.PlayerPID != first.PlayerPID
	})
	if clear.DVR || clear.BufferMinutes != 0 || clear.BufferEnd != 0 || clear.Paused {
		t.Fatal("opt out retained history", clear)
	}
	if err := syscall.Kill(first.PlayerPID, 0); err == nil {
		t.Fatal("old buffered player survived opt out")
	}
	h.stop()

	// Starting from Live only must activate the provisioned cache without reconnecting.
	requests.Store(0)
	h2 := newHarness(t, Config{StationFile: path, MPV: mpv, MPVArgs: []string{"--ao=null"}, DVRPollInterval: 100 * time.Millisecond}, false)
	liveFirst := h2.play()
	time.Sleep(2 * time.Second)
	h2.send("pause")
	temporary := h2.wait(func(s Status) bool { return s.Paused && s.TemporaryBuffer && s.DVR })
	grown := h2.wait(func(s Status) bool { return s.Paused && s.BufferEnd > temporary.BufferEnd+5 })
	if grown.BufferMinutes != 0 || grown.PlayerPID != liveFirst.PlayerPID || requests.Load() != 1 || math.Abs(grown.Position-temporary.Position) > .3 {
		t.Fatal("temporary pause did not preserve the live connection and position", temporary, grown, requests.Load())
	}
	h2.send("play")
	resumedTemp := h2.wait(func(s Status) bool { return !s.Paused && s.TemporaryBuffer && s.Position > grown.Position+.2 })
	if resumedTemp.PlayerPID != liveFirst.PlayerPID || requests.Load() != 1 {
		t.Fatal("temporary resume reconnected", resumedTemp)
	}
	stopped := h2.stop()
	if stopped.TemporaryBuffer || stopped.DVR || stopped.BufferMinutes != 0 {
		t.Fatal("temporary buffer survived stop", stopped)
	}
}

func TestPauseIgnoresStaleObservationsAndAllowsExternalControl(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	go func() { _, _ = io.Copy(io.Discard, server) }()
	r := &controller{
		state:  Status{State: "playing", Wanted: true},
		cfg:    Config{DVRWindow: 15 * time.Minute, StallTimeout: time.Second},
		player: &player{conn: client, started: time.Now()},
		output: json.NewEncoder(io.Discard),
	}
	defer r.clearTimer()
	prop := func(v bool) { r.event(mpvEvent{Event: "property-change", Name: "pause", Data: v}) }
	if err := r.setPaused(true); err != nil {
		t.Fatal(err)
	}
	prop(false)
	if !r.state.Paused || r.player.pendingPause == nil {
		t.Fatal("stale unpause undid pause", r.state)
	}
	// Rapid toggles must fence old observations against the latest intent.
	if err := r.setPaused(false); err != nil {
		t.Fatal(err)
	}
	if err := r.setPaused(true); err != nil {
		t.Fatal(err)
	}
	prop(false)
	if !r.state.Paused {
		t.Fatal("stale event undid latest toggle", r.state)
	}
	prop(true)
	if r.player.pendingPause != nil {
		t.Fatal("latest observation did not acknowledge pause")
	}
	prop(false)
	if r.state.Paused {
		t.Fatal("external resume was ignored", r.state)
	}
	prop(true)
	if !r.state.Paused {
		t.Fatal("external pause was ignored", r.state)
	}
}
