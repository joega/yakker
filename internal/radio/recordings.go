package radio

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"os"
	"time"

	"github.com/joega/yakker/internal/recording"
)

func (r *controller) openRecorder() {
	cfg := recording.Config{}
	if r.cfg.RecordingConfig != nil {
		cfg = *r.cfg.RecordingConfig
	}
	manager, err := recording.Open(cfg)
	if err != nil {
		r.state.Recordings = &recording.Snapshot{Error: "Recording storage could not be opened. Check the data folder and restart Yakker.", Schedules: []recording.Schedule{}, Recordings: []recording.Recording{}}
		return
	}
	r.recorder = manager
	r.refreshRecordings()
}

func (r *controller) refreshRecordings() {
	if r.recorder != nil {
		snapshot := r.recorder.Snapshot()
		r.state.Recordings = &snapshot
	}
}

func decodeRecordingField(data map[string]json.RawMessage, field string, target any) error {
	raw := data[field]
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return errors.New("Missing " + field)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return errors.New("Invalid " + field)
	}
	return nil
}

func (r *controller) recordingCommand(action string, data map[string]json.RawMessage) {
	r.state.RecordingMutationSerial = r.state.Serial
	r.state.RecordingMutationOK = false
	r.state.RecordingError = ""
	err := r.applyRecordingCommand(action, data)
	if err != nil {
		r.state.RecordingError = head(err.Error(), 240)
	} else {
		r.state.RecordingMutationOK = true
	}
	r.refreshRecordings()
}

func (r *controller) resolveRecordingStation(schedule *recording.Schedule, refresh bool) error {
	if refresh {
		for _, station := range r.stations {
			if station["id"] == schedule.StationID {
				schedule.StationName, _ = station["name"].(string)
				schedule.StreamURL, _ = station["streamUrl"].(string)
				return nil
			}
		}
	}
	if r.recorder != nil {
		for _, saved := range r.recorder.Snapshot().Schedules {
			if saved.ID == schedule.ID && saved.StationID == schedule.StationID {
				schedule.StationName, schedule.StreamURL = saved.StationName, saved.StreamURL
				return nil
			}
		}
	}
	for _, station := range r.stations {
		if station["id"] == schedule.StationID {
			schedule.StationName, _ = station["name"].(string)
			schedule.StreamURL, _ = station["streamUrl"].(string)
			return nil
		}
	}
	return errors.New("Choose an available station for this schedule.")
}

func (r *controller) previewScheduleCommand(data map[string]json.RawMessage) {
	r.state.SchedulePreviewSerial = r.state.Serial
	r.state.SchedulePreview, r.state.SchedulePreviewError = nil, ""
	var schedule recording.Schedule
	err := decodeRecordingField(data, "schedule", &schedule)
	if err == nil {
		err = r.resolveRecordingStation(&schedule, false)
	}
	if err == nil {
		now := time.Now()
		if r.cfg.RecordingConfig != nil && r.cfg.RecordingConfig.Now != nil {
			now = r.cfg.RecordingConfig.Now()
		}
		schedule, err = recording.PreviewSchedule(schedule, now)
	}
	if err != nil {
		r.state.SchedulePreviewError = head(err.Error(), 240)
	} else {
		r.state.SchedulePreview = &schedule
	}
}

func (r *controller) applyRecordingCommand(action string, data map[string]json.RawMessage) error {
	if r.recorder == nil {
		return errors.New("Recordings are unavailable. Reopen the bar player and try again.")
	}
	var revision int64
	if err := decodeRecordingField(data, "revision", &revision); err != nil {
		return err
	}
	switch action {
	case "startRecording":
		var stationID string
		var minutes int
		if err := decodeRecordingField(data, "stationId", &stationID); err != nil {
			return err
		}
		if err := decodeRecordingField(data, "durationMinutes", &minutes); err != nil {
			return err
		}
		if minutes < 1 || minutes > 720 {
			return errors.New("Recording duration must be between 1 and 720 minutes.")
		}
		schedule := recording.Schedule{StationID: stationID}
		if err := r.resolveRecordingStation(&schedule, true); err != nil {
			return err
		}
		return r.recorder.StartNow(revision, schedule, time.Duration(minutes)*time.Minute)
	case "recordingSettings":
		var settings recording.Settings
		if err := decodeRecordingField(data, "settings", &settings); err != nil {
			return err
		}
		return r.recorder.SetSettings(revision, settings)
	case "upsertSchedule":
		var schedule recording.Schedule
		if err := decodeRecordingField(data, "schedule", &schedule); err != nil {
			return err
		}
		if schedule.ID != "" {
			found := false
			for _, saved := range r.recorder.Snapshot().Schedules {
				if saved.ID == schedule.ID {
					found = true
					break
				}
			}
			if !found {
				return errors.New("This schedule was removed. Create a new schedule instead.")
			}
		}
		// Resolve identity independently of metadata supplied over IPC.
		refresh := false
		if _, present := data["refreshStation"]; present {
			if err := decodeRecordingField(data, "refreshStation", &refresh); err != nil {
				return err
			}
		}
		if err := r.resolveRecordingStation(&schedule, refresh); err != nil {
			return err
		}
		return r.recorder.UpsertSchedule(revision, schedule)
	case "deleteSchedule", "stopRecording", "deleteRecording":
		var id string
		if err := decodeRecordingField(data, "id", &id); err != nil {
			return err
		}
		if action == "deleteSchedule" {
			return r.recorder.DeleteSchedule(revision, id)
		}
		if action == "stopRecording" {
			return r.recorder.StopRecording(revision, id)
		}
		if r.state.Wanted && r.state.PlaybackKind == "recording" && r.state.RecordingID == id {
			return errors.New("Stop playback before deleting this recording.")
		}
		return r.recorder.DeleteRecording(revision, id)
	}
	return errors.New("Unknown recording command")
}

func (r *controller) playRecordingCommand(data map[string]json.RawMessage) error {
	if r.recorder == nil {
		return errors.New("Recordings are unavailable.")
	}
	var id string
	if err := decodeRecordingField(data, "id", &id); err != nil {
		return err
	}
	var fromStart bool
	if _, ok := data["fromStart"]; ok {
		if err := decodeRecordingField(data, "fromStart", &fromStart); err != nil {
			return err
		}
	}
	item, path, err := r.recorder.RecordingPath(id)
	if err != nil {
		return err
	}
	r.stop()
	// Stopping may have just checkpointed this same recording.
	item, path, err = r.recorder.RecordingPath(id)
	if err != nil {
		return err
	}
	if fromStart {
		if err := r.recorder.SetPlaybackPosition(id, 0); err != nil {
			return err
		}
		item.ResumePosition = 0
	}
	r.state.PlaybackProgressError = ""
	r.state.PlaybackKind, r.state.RecordingID = "recording", item.ID
	r.state.RecordingTitle = item.Label
	if r.state.RecordingTitle == "" {
		r.state.RecordingTitle = item.StationName
	}
	r.state.Duration, r.recordingPath = item.DurationSeconds, path
	r.recordingStart = item.ResumePosition

	r.state.PlaybackSpeed = 1
	r.lastCheckpoint = time.Time{}
	r.startRecordingPlayback()
	return nil
}

func (r *controller) startRecordingPlayback() {
	info, err := os.Lstat(r.recordingPath)
	if err != nil || !info.Mode().IsRegular() {
		r.state.Wanted, r.state.State = false, "error"
		r.state.Error = "The recording file is no longer available."
		return
	}
	r.state.Wanted = true
	r.state.Error, r.state.Retry, r.state.RetryDelay = "", 0, 0
	r.start()
}

func (r *controller) selectLivePlayback() {
	r.state.PlaybackProgressError = ""
	r.state.PlaybackKind = "live"
	r.state.RecordingID, r.state.RecordingTitle, r.recordingPath = "", "", ""
	r.state.Duration = 0
	r.state.PlaybackSpeed, r.recordingStart = 1, 0
}

func (r *controller) seekRecordingCommand(data map[string]json.RawMessage) error {
	var value float64
	if err := decodeRecordingField(data, "value", &value); err != nil {
		return err
	}
	return r.seekFile(value)
}

func (r *controller) seekFile(value float64) error {
	if !r.state.Wanted || r.player == nil || r.player.conn == nil || r.state.PlaybackKind != "recording" {
		return errors.New("Play a recording before seeking.")
	}
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return errors.New("Seek must be a finite number of seconds.")
	}
	if r.state.Duration <= 0 {
		return errors.New("The recording duration is not available yet.")
	}
	value = math.Max(0, math.Min(math.Max(0, r.state.Duration-.05), value))
	return r.ipc([]any{"seek", value, "absolute+exact"})
}

func (r *controller) fileDuration(value any) {
	if r.state.PlaybackKind != "recording" {
		return
	}
	if duration, ok := value.(float64); ok && !math.IsNaN(duration) && !math.IsInf(duration, 0) && duration > 0 {
		r.state.Duration = duration
	}
}

// Local files do not receive network-intake heartbeats while paused.
func (r *controller) pausedFile() bool { return r.state.PlaybackKind == "recording" && r.state.Paused }

func (r *controller) fileTicker() {
	if r.dvrTicker == nil {
		r.dvrTicker = time.NewTicker(r.cfg.DVRPollInterval)
	}
}

// Progress belongs to the current player and is written only by the manager.
func (r *controller) checkpoint(force, completed bool) {
	if r.recorder == nil || r.player == nil || r.state.PlaybackKind != "recording" || r.state.RecordingID == "" {
		return
	}
	now := time.Now()
	if r.cfg.Now != nil {
		now = r.cfg.Now()
	}
	if !force && !r.lastCheckpoint.IsZero() && now.Sub(r.lastCheckpoint) < 10*time.Second {
		return
	}
	position := r.currentPosition()
	if completed || (r.state.Duration > 0 && position >= math.Max(0, r.state.Duration-2)) {
		position = 0
	}
	if err := r.recorder.SetPlaybackPosition(r.state.RecordingID, position); err != nil {
		r.state.PlaybackProgressError = head("Unable to save playback position: "+err.Error(), 240)
		return
	}
	r.state.PlaybackProgressError = ""
	r.recordingStart = position
	r.lastCheckpoint = now
	r.refreshRecordings()
}

func (r *controller) speedCommand(data map[string]json.RawMessage) error {
	var value float64
	if err := decodeRecordingField(data, "value", &value); err != nil {
		return err
	}
	if value != .75 && value != 1 && value != 1.25 && value != 1.5 && value != 2 {
		return errors.New("Choose a supported playback speed.")
	}
	if r.state.PlaybackKind != "recording" || !r.state.Wanted {
		return errors.New("Play a recording before changing speed.")
	}
	if err := r.ipc([]any{"set_property", "speed", value}); err != nil {
		return err
	}
	r.state.PlaybackSpeed = value
	return nil
}

func (r *controller) sleepCommand(data map[string]json.RawMessage) error {
	var minutes int
	if err := decodeRecordingField(data, "minutes", &minutes); err != nil {
		return err
	}
	if minutes < 0 || minutes > 240 {
		return errors.New("Sleep timer must be between 0 and 240 minutes.")
	}
	r.cancelSleep()
	if minutes == 0 {
		return nil
	}
	now := time.Now()
	if r.cfg.Now != nil {
		now = r.cfg.Now()
	}
	r.sleepDeadline = now.Add(time.Duration(minutes) * time.Minute)
	r.state.SleepRemaining = minutes * 60
	r.sleepTicker = time.NewTicker(time.Second)
	return nil
}

func (r *controller) cancelSleep() {
	if r.sleepTicker != nil {
		r.sleepTicker.Stop()
		r.sleepTicker = nil
	}
	r.sleepDeadline = time.Time{}
	r.state.SleepRemaining = 0
}

func (r *controller) updateSleep() {
	if r.sleepDeadline.IsZero() {
		return
	}
	now := time.Now()
	if r.cfg.Now != nil {
		now = r.cfg.Now()
	}
	remaining := r.sleepDeadline.Sub(now)
	if remaining <= 0 {
		r.cancelSleep()
		r.stop()
		return
	}
	r.state.SleepRemaining = int(math.Ceil(remaining.Seconds()))
}
