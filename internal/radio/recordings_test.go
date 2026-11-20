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
	"testing"
	"time"

	"github.com/joega/yakker/internal/recording"
)

func TestRecordingProtocolPersistsWithoutAutoplayAndRejectsStaleEdits(t *testing.T) {
	base := tempDir(t)
	cfg := &recording.Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "music"), PollInterval: time.Hour}
	h := newHarness(t, Config{RecordingConfig: cfg}, false)
	initial := h.barrier()
	if initial.Recordings == nil || initial.Recordings.Revision == 0 || initial.Wanted {
		t.Fatal("recorder initialization changed playback", initial)
	}
	settings := initial.Recordings.Settings
	settings.Folder, settings.StorageCapBytes, settings.FreeSpaceReserveBytes = filepath.Join(base, "chosen"), 1<<30, 0
	serial := h.send("recordingSettings", "revision", initial.Recordings.Revision, "settings", settings)
	saved := h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !saved.RecordingMutationOK || saved.Wanted || saved.Recordings.Settings.Folder != settings.Folder {
		t.Fatal("save settings", saved)
	}
	if _, err := os.Stat(settings.Folder); !os.IsNotExist(err) {
		t.Fatal("settings created media folder before recording", err)
	}
	rule := recording.Schedule{Label: "<b>Friday segment</b>", StationID: "wbz-fm", StationName: "Spoofed station", StreamURL: "file:///not-a-stream", Weekdays: []int{5}, StartTime: "14:00", EndTime: "14:20", Timezone: "America/New_York", Enabled: false}
	previewRule := rule
	previewRule.Enabled = true
	serial = h.send("previewSchedule", "schedule", previewRule)
	preview := h.wait(func(s Status) bool { return s.SchedulePreviewSerial == serial })
	if preview.SchedulePreview == nil || preview.SchedulePreview.NextStart == "" || preview.Recordings.Revision != saved.Recordings.Revision || preview.Wanted {
		t.Fatal("preview mutated persisted state or started playback", preview)
	}
	serial = h.send("upsertSchedule", "revision", saved.Recordings.Revision, "schedule", rule)
	created := h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !created.RecordingMutationOK || len(created.Recordings.Schedules) != 1 || created.Wanted {
		t.Fatal("save schedule", created)
	}
	actual := created.Recordings.Schedules[0]
	if actual.StationName == rule.StationName || actual.StreamURL == rule.StreamURL || actual.Label != rule.Label {
		t.Fatal("station snapshot not resolved from catalogue", actual)
	}
	before, err := os.ReadFile(filepath.Join(cfg.DataDir, "recordings.json"))
	if err != nil {
		t.Fatal(err)
	}
	settings.StorageCapBytes = 2 << 30
	serial = h.send("recordingSettings", "revision", saved.Recordings.Revision, "settings", settings)
	stale := h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	after, err := os.ReadFile(filepath.Join(cfg.DataDir, "recordings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if stale.RecordingMutationOK || stale.RecordingError == "" || stale.Error != "" || string(before) != string(after) {
		t.Fatal("stale recording edit changed data or radio state", stale)
	}
	serial = h.send("upsertSchedule", "revision", created.Recordings.Revision, "schedule", map[string]any{"stationId": "not-in-catalogue"})
	unknown := h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if unknown.RecordingMutationOK || unknown.RecordingError == "" || unknown.Wanted {
		t.Fatal("unknown recording station accepted", unknown)
	}
	serial = h.send("deleteSchedule", "revision", created.Recordings.Revision, "id", actual.ID)
	removed := h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !removed.RecordingMutationOK || len(removed.Recordings.Schedules) != 0 || removed.Wanted {
		t.Fatal("delete schedule", removed)
	}
}

func TestExplicitSessionsDoNotOpenRecordingStorage(t *testing.T) {
	base := tempDir(t)
	for _, cfg := range []Config{{}, {DisableRecordings: true, RecordingConfig: &recording.Config{DataDir: filepath.Join(base, "disabled"), DefaultFolder: filepath.Join(base, "music")}}} {
		h := newHarness(t, cfg, false)
		if h.barrier().Recordings != nil {
			t.Fatal("isolated session opened a scheduler")
		}
	}
	if _, err := os.Stat(filepath.Join(base, "disabled")); !os.IsNotExist(err) {
		t.Fatal("disabled scheduler touched persistent storage", err)
	}
}

func TestRecordedFilePauseSeekAndEOFAreIndependentOfLiveBuffer(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	commands := make(chan []any, 16)
	go func() {
		decoder := json.NewDecoder(server)
		for {
			var command struct {
				Command []any `json:"command"`
			}
			if decoder.Decode(&command) != nil {
				return
			}
			commands <- command.Command
		}
	}()
	r := &controller{cfg: Config{DVRPollInterval: time.Second, StallTimeout: 30 * time.Second}, state: Status{State: "playing", Wanted: true, PlaybackKind: "recording", Duration: 10}, player: &player{conn: client, started: time.Now().Add(-time.Minute)}, output: json.NewEncoder(io.Discard)}
	defer r.clearTimer()
	if err := r.setPaused(true); err != nil {
		t.Fatal(err)
	}
	<-commands
	if !r.state.Paused || r.state.TemporaryBuffer || r.state.DVR || r.watchdogRemaining() != r.cfg.StallTimeout {
		t.Fatal("file pause used live buffer or timed out", r.state)
	}
	if err := r.seekFile(100); err != nil {
		t.Fatal(err)
	}
	cmd := <-commands
	if cmd[0] != "seek" || math.Abs(cmd[1].(float64)-9.95) > .001 {
		t.Fatal("file seek did not clamp to duration", cmd)
	}
	if err := r.seekFile(math.NaN()); err == nil {
		t.Fatal("accepted nonfinite file seek")
	}
	if err := r.setPaused(false); err != nil {
		t.Fatal(err)
	}
	<-commands
	if r.state.Paused || r.state.TemporaryBuffer {
		t.Fatal("resume enabled live buffering", r.state)
	}
	r.player = nil
	r.event(mpvEvent{Event: "end-file", Reason: "eof"})
	if r.state.Wanted || r.state.State != "stopped" || r.state.Retry != 0 {
		t.Fatal("file EOF attempted reconnect", r.state)
	}
}

func recordingAudioServer(t *testing.T) (string, *atomic.Int32) {
	t.Helper()
	active := &atomic.Int32{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		active.Add(1)
		defer active.Add(-1)
		w.Header().Set("Content-Type", "audio/wav")
		header := make([]byte, 44)
		copy(header, "RIFF")
		binary.LittleEndian.PutUint32(header[4:], 0x7fffffff)
		copy(header[8:], "WAVEfmt ")
		binary.LittleEndian.PutUint32(header[16:], 16)
		binary.LittleEndian.PutUint16(header[20:], 1)
		binary.LittleEndian.PutUint16(header[22:], 1)
		binary.LittleEndian.PutUint32(header[24:], 48000)
		binary.LittleEndian.PutUint32(header[28:], 96000)
		binary.LittleEndian.PutUint16(header[32:], 2)
		binary.LittleEndian.PutUint16(header[34:], 16)
		copy(header[36:], "data")
		binary.LittleEndian.PutUint32(header[40:], 0x7fffffdb)
		if _, err := w.Write(header); err != nil {
			return
		}
		w.(http.Flusher).Flush()
		ticker := time.NewTicker(50 * time.Millisecond)
		defer ticker.Stop()
		sample := 0
		for {
			select {
			case <-req.Context().Done():
				return
			case <-ticker.C:
				block := make([]byte, 4800)
				for i := 0; i < 2400; i++ {
					binary.LittleEndian.PutUint16(block[2*i:], uint16(int16(12000*math.Sin(2*math.Pi*440*float64(sample)/48000))))
					sample++
				}
				if _, err := w.Write(block); err != nil {
					return
				}
				w.(http.Flusher).Flush()
			}
		}
	}))
	t.Cleanup(server.Close)
	return server.URL, active
}

// This verifies the real controller, scheduler, independent encoders, private
// recording files and foreground mpv against local audio only.
func TestRealRecordingLifecycleAndForegroundIndependence(t *testing.T) {
	if os.Getenv("YAKKER_TEST_REAL_MPV") != "1" {
		t.Skip("set YAKKER_TEST_REAL_MPV=1 for recording integration")
	}
	for _, tool := range []string{"mpv", "ffmpeg", "ffprobe"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatal(err)
		}
	}
	url, active := recordingAudioServer(t)
	base := tempDir(t)
	stationPath := filepath.Join(base, "stations.json")
	stations := []Station{{"id": "one", "name": "One", "subtitle": "Local fixture", "streamUrl": url}, {"id": "two", "name": "Two", "subtitle": "Local fixture", "streamUrl": url}}
	data, _ := json.Marshal(stations)
	if err := os.WriteFile(stationPath, data, 0600); err != nil {
		t.Fatal(err)
	}
	recorderCfg := &recording.Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "music"), PollInterval: 100 * time.Millisecond, StopGrace: 2 * time.Second}
	h := newHarness(t, Config{StationFile: stationPath, MPV: "mpv", MPVArgs: []string{"--ao=null"}, RecordingConfig: recorderCfg, DVRPollInterval: 100 * time.Millisecond}, false)
	state := h.barrier()
	settings := state.Recordings.Settings
	settings.FreeSpaceReserveBytes = 0
	serial := h.send("recordingSettings", "revision", state.Recordings.Revision, "settings", settings)
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK {
		t.Fatal(state.RecordingError)
	}
	now := time.Now().UTC()
	for i := 0; i < 2; i++ {
		rule := recording.Schedule{Label: []string{"First", "Second"}[i], StationID: "one", Weekdays: []int{int(now.Weekday())}, StartTime: now.Format("15:04"), EndTime: now.Add(3 * time.Minute).Format("15:04"), Timezone: "UTC", Enabled: true}
		serial = h.send("upsertSchedule", "revision", state.Recordings.Revision, "schedule", rule)
		state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
		if !state.RecordingMutationOK {
			t.Fatal(state.RecordingError)
		}
	}
	state = h.wait(func(s Status) bool { return s.Recordings != nil && s.Recordings.ActiveCount == 2 })
	if state.Wanted {
		t.Fatal("scheduled captures started audible playback")
	}
	h.play()
	h.stop()
	serial = h.send("configure", "stationId", "two")
	state = h.wait(func(s Status) bool { return s.Serial == serial })
	if state.Recordings.ActiveCount != 2 || state.Wanted || state.Station["id"] != "two" {
		t.Fatal("foreground changes affected captures", state)
	}
	state = h.wait(func(s Status) bool { return s.Recordings.ActiveCount == 2 && s.Recordings.UsedBytes > 0 })
	id := state.Recordings.Recordings[0].ID
	serial = h.send("stopRecording", "revision", state.Recordings.Revision, "id", id)
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK {
		t.Fatal(state.RecordingError)
	}
	state = h.wait(func(s Status) bool {
		if s.Recordings.ActiveCount != 1 {
			return false
		}
		for _, item := range s.Recordings.Recordings {
			if item.ID == id {
				return item.Status == "partial" && item.DurationSeconds > 0
			}
		}
		return false
	})
	serial = h.send("playRecording", "id", id)
	file := h.wait(func(s Status) bool {
		return s.Serial == serial && s.PlaybackKind == "recording" && s.State == "playing"
	})
	if file.RecordingID != id || file.Duration <= 0 || file.DVR || file.Recordings.ActiveCount != 1 {
		t.Fatal("file playback not independent", file)
	}
	h.send("pause")
	paused := h.wait(func(s Status) bool { return s.Paused && s.State == "paused" })
	if paused.TemporaryBuffer || paused.BufferMinutes != 0 || paused.Recordings.ActiveCount != 1 {
		t.Fatal("file pause created live DVR", paused)
	}
	h.send("seekRecording", "value", 2)
	h.wait(func(s Status) bool { return s.Paused && s.Position > 1.5 && s.Position < 2.5 })
	h.send("live")
	returned := h.wait(func(s Status) bool { return s.PlaybackKind == "live" && s.State == "playing" })
	if returned.Station["id"] != "two" || returned.Recordings.ActiveCount != 1 {
		t.Fatal("return to live affected capture or selection", returned)
	}
	h.stop()
	h.send("quit")
	select {
	case err := <-h.done:
		h.done <- err
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("plugin shutdown did not reap captures")
	}
	deadline := time.Now().Add(3 * time.Second)
	for active.Load() != 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if active.Load() != 0 {
		t.Fatal("capture or foreground network connection survived plugin shutdown")
	}
	data, err := os.ReadFile(filepath.Join(recorderCfg.DataDir, "recordings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var index struct {
		Recordings []recording.Recording `json:"recordings"`
	}
	if err := json.Unmarshal(data, &index); err != nil {
		t.Fatal(err)
	}
	for _, item := range index.Recordings {
		if item.Status == "recording" {
			t.Fatal("shutdown left an active persisted capture", item)
		}
	}
}
