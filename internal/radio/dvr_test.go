package radio

import (
	"encoding/binary"
	"encoding/json"
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
		t.Fatal("Live only allowed a pause")
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
}
