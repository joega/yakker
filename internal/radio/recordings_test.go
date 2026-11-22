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

func TestScheduleRefreshUsesTrustedStationAndPreservesSavedSourceUntilSave(t *testing.T) {
	base := tempDir(t)
	h := newHarness(t, Config{CustomStationFile: filepath.Join(base, "custom.json"), RecordingConfig: &recording.Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "media"), PollInterval: time.Hour}}, false)
	custom := CustomStation{Name: "Custom", StreamURL: "https://example.test/old"}
	serial := h.send("upsertStation", "station", custom)
	state := h.wait(func(s Status) bool { return s.CustomMutationSerial == serial })
	if !state.CustomMutationOK {
		t.Fatal(state.CustomStationError)
	}
	for _, station := range state.Stations {
		if station["custom"] == true {
			custom.ID, _ = station["id"].(string)
		}
	}
	rule := recording.Schedule{StationID: custom.ID, Weekdays: []int{1}, StartTime: "10:00", EndTime: "10:20", Timezone: "UTC"}
	serial = h.send("upsertSchedule", "revision", state.Recordings.Revision, "schedule", rule)
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK {
		t.Fatal(state.RecordingError)
	}
	rule = state.Recordings.Schedules[0]
	custom.StreamURL = "https://example.test/new"
	serial = h.send("upsertStation", "station", custom)
	state = h.wait(func(s Status) bool { return s.CustomMutationSerial == serial })
	if state.Recordings.Schedules[0].StreamURL != "https://example.test/old" {
		t.Fatal("station edit silently changed a saved recording source")
	}
	rule.StreamURL = "file:///untrusted"
	serial = h.send("upsertSchedule", "revision", state.Recordings.Revision, "schedule", rule, "refreshStation", true)
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK || state.Recordings.Schedules[0].StreamURL != custom.StreamURL || state.Wanted {
		t.Fatal("explicit refresh did not use trusted current stream", state.RecordingError)
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
	serial = h.send("startRecording", "revision", state.Recordings.Revision, "stationId", "one", "durationMinutes", 15, "stationName", "Spoofed", "streamUrl", "file:///spoofed")
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK || len(state.Recordings.Schedules) != 0 || len(state.Recordings.Recordings) != 1 || state.Recordings.Recordings[0].StationName != "One" {
		t.Fatal("record now did not use catalogue station", state)
	}
	rule := recording.Schedule{Label: "Second", StationID: "one", Weekdays: []int{int(now.Weekday())}, StartTime: now.Format("15:04"), EndTime: now.Add(3 * time.Minute).Format("15:04"), Timezone: "UTC", Enabled: true}
	serial = h.send("upsertSchedule", "revision", state.Recordings.Revision, "schedule", rule)
	state = h.wait(func(s Status) bool { return s.RecordingMutationSerial == serial })
	if !state.RecordingMutationOK {
		t.Fatal(state.RecordingError)
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
	// Retain enough media to exercise a nonterminal resume point.
	time.Sleep(5 * time.Second)
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
	serial = h.send("configure", "stationId", "")
	h.wait(func(s Status) bool { return s.Serial == serial && len(s.Station) == 0 })
	serial = h.send("playRecording", "id", id)
	file := h.wait(func(s Status) bool {
		return s.Serial == serial && s.PlaybackKind == "recording" && s.State == "playing"
	})
	if file.RecordingID != id || file.Duration <= 0 || file.DVR || file.Recordings.ActiveCount != 1 {
		t.Fatal("file playback not independent", file)
	}
	serial = h.send("speed", "value", 1.5)
	file = h.wait(func(s Status) bool { return s.Serial == serial })
	if file.PlaybackSpeed != 1.5 {
		t.Fatal("speed change failed", file)
	}
	h.send("pause")
	paused := h.wait(func(s Status) bool { return s.Paused && s.State == "paused" })
	if paused.TemporaryBuffer || paused.BufferMinutes != 0 || paused.Recordings.ActiveCount != 1 {
		t.Fatal("file pause created live DVR", paused)
	}
	h.send("seekRecording", "value", 2)
	h.wait(func(s Status) bool { return s.Paused && s.Position > 1.5 && s.Position < 2.5 })
	serial = h.send("live")
	withoutStation := h.wait(func(s Status) bool { return s.Serial == serial })
	if withoutStation.Error == "" || withoutStation.PlaybackKind != "recording" || withoutStation.RecordingID != id || !withoutStation.Wanted {
		t.Fatal("return to live without station interrupted recording", withoutStation)
	}
	h.send("play")
	h.wait(func(s Status) bool { return s.PlaybackKind == "recording" && s.State == "playing" })
	serial = h.send("configure", "stationId", "two")
	returned := h.wait(func(s Status) bool { return s.Serial == serial && s.PlaybackKind == "live" && s.State == "playing" })
	if returned.Station["id"] != "two" || returned.Recordings.ActiveCount != 1 || returned.PlaybackSpeed != 1 {
		t.Fatal("return to live affected capture or selection", returned)
	}

	serial = h.send("playRecording", "id", id)
	resumed := h.wait(func(s Status) bool {
		return s.Serial == serial && s.PlaybackKind == "recording" && s.State == "playing"
	})
	resumed = h.wait(func(s Status) bool { return s.Serial == serial && s.Position > 1.5 })
	if resumed.Position < 1.5 {
		t.Fatal("recording did not resume", resumed)
	}
	serial = h.send("playRecording", "id", id, "fromStart", true)
	restarted := h.wait(func(s Status) bool {
		return s.Serial == serial && s.PlaybackKind == "recording" && s.State == "playing"
	})
	if restarted.Position > 1.5 {
		t.Fatal("recording did not restart", restarted)
	}
	h.send("seekRecording", "value", math.Max(0, restarted.Duration-.4))
	finished := h.wait(func(s Status) bool { return !s.Wanted && s.State == "stopped" })
	for _, part := range finished.Recordings.Recordings {
		if part.ID == id && (!part.PlaybackCompleted || part.ResumePosition != 0 || part.LastPlayedAt == "") {
			t.Fatal("EOF lost the completed-part bookmark", part)
		}
	}
	h.stop()
	for _, part := range h.barrier().Recordings.Recordings {
		if part.ID == id && !part.PlaybackCompleted {
			t.Fatal("Stop after EOF erased part completion", part)
		}
	}
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

func TestSleepAndSpeedCommands(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	r := &controller{cfg: Config{Now: func() time.Time { return now }}, state: Status{PlaybackKind: "live", PlaybackSpeed: 1}}
	command := func(s string) error { _, err := r.command([]byte(s)); return err }
	for _, s := range []string{`{"action":"sleepTimer","minutes":-1}`, `{"action":"sleepTimer","minutes":241}`, `{"action":"sleepTimer","minutes":1.5}`, `{"action":"sleepTimer","minutes":null}`, `{"action":"speed","value":1.5}`} {
		if command(s) == nil {
			t.Fatalf("accepted %s", s)
		}
	}
	if err := command(`{"action":"sleepTimer","minutes":15}`); err != nil {
		t.Fatal(err)
	}
	defer r.cancelSleep()
	now = now.Add(14*time.Minute + 59*time.Second)
	r.updateSleep()
	if r.state.SleepRemaining != 1 {
		t.Fatal(r.state.SleepRemaining)
	}
	now = now.Add(time.Second)
	r.updateSleep()
	if r.state.SleepRemaining != 0 || r.state.State != "stopped" {
		t.Fatal(r.state)
	}
	r.state.PlaybackKind, r.state.Wanted = "recording", true
	if err := command(`{"action":"speed","value":1.5}`); err != nil || r.state.PlaybackSpeed != 1.5 {
		t.Fatal(err, r.state.PlaybackSpeed)
	}
	for _, s := range []string{`{"action":"speed","value":1.1}`, `{"action":"speed","value":"2"}`, `{"action":"speed","value":null}`} {
		if command(s) == nil {
			t.Fatalf("accepted %s", s)
		}
	}
	r.selectLivePlayback()
	if r.state.PlaybackSpeed != 1 {
		t.Fatal(r.state.PlaybackSpeed)
	}
	if err := command(`{"action":"sleepTimer","minutes":1}`); err != nil {
		t.Fatal(err)
	}
	if err := command(`{"action":"stop"}`); err != nil || !r.sleepDeadline.IsZero() {
		t.Fatal(err, r.sleepDeadline)
	}
}

func TestStartRecordingInputValidation(t *testing.T) {
	base := t.TempDir()
	manager, err := recording.Open(recording.Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "media"), PollInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.Close()
	r := &controller{recorder: manager, stations: []Station{{"id": "one", "name": "Real", "streamUrl": "https://example.test/audio"}}}
	revision := manager.Snapshot().Revision
	for _, data := range []string{`{"stationId":"one","durationMinutes":0}`, `{"stationId":"one","durationMinutes":721}`, `{"stationId":"one","durationMinutes":1.5}`, `{"stationId":"unknown","durationMinutes":15}`} {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(data), &fields); err != nil {
			t.Fatal(err)
		}
		fields["revision"], _ = json.Marshal(revision)
		if err := r.applyRecordingCommand("startRecording", fields); err == nil {
			t.Fatalf("accepted %s", data)
		}
	}
	if len(manager.Snapshot().Recordings) != 0 {
		t.Fatal("invalid request created capture")
	}
}

func TestCheckpointUsesCurrentPlayerAndReportsStorageFailure(t *testing.T) {
	base := t.TempDir()
	manager, err := recording.Open(recording.Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "media"), PollInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(); err != nil {
		t.Fatal(err)
	}
	old, current := &player{}, &player{}
	old.position.Store(math.Float64bits(70))
	current.position.Store(math.Float64bits(12))
	r := &controller{recorder: manager, player: current, state: Status{PlaybackKind: "recording", RecordingID: "current", Duration: 100}}
	// An old socket reader updates only its own atomic progress field.
	old.consumeProgress(mpvEvent{Event: "property-change", Name: "time-pos", Data: float64(95)})
	if r.currentPosition() != 12 {
		t.Fatal("stale player changed current progress")
	}
	r.checkpoint(true, false)
	if r.state.PlaybackProgressError == "" {
		t.Fatal("checkpoint failure was not exposed")
	}
	r.state.Error = "unrelated playback error"
	r.selectLivePlayback()
	if r.state.PlaybackProgressError != "" || r.state.Error != "unrelated playback error" {
		t.Fatal("selecting live did not isolate progress errors", r.state)
	}
}
