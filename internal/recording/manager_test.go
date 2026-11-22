package recording

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeCapture struct {
	once sync.Once
	done chan CaptureResult
}

func (c *fakeCapture) Done() <-chan CaptureResult { return c.done }
func (c *fakeCapture) Stop() {
	c.once.Do(func() { c.done <- CaptureResult{Bytes: 40, DurationSeconds: 5}; close(c.done) })
}

func engineFixture(t *testing.T) (*Manager, *time.Time, *int) {
	t.Helper()
	now := time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC)
	base := t.TempDir()
	count := 0
	m, err := Open(Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "music"), Now: func() time.Time { return now }, PollInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		count++
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m.dependencyError = "" // The deterministic fixture replaces the encoder.
	m.freeBytes = func(string) (int64, error) { return 1 << 40, nil }
	t.Cleanup(func() {
		if err := m.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return m, &now, &count
}
func rule(id string) Schedule {
	return Schedule{ID: id, StationID: "station", StationName: "Station", StreamURL: "https://example.test/live", Weekdays: []int{1}, StartTime: "10:00", EndTime: "11:00", Timezone: "UTC", Enabled: true}
}
func saveRule(t *testing.T, m *Manager, s Schedule) {
	t.Helper()
	if err := m.UpsertSchedule(m.Snapshot().Revision, s); err != nil {
		t.Fatal(err)
	}
}
func tick(m *Manager) { m.mu.Lock(); defer m.mu.Unlock(); m.tickLocked() }

func TestPaddedCaptureKeepsProgramWindowAndResumesThroughPostRoll(t *testing.T) {
	m, now, count := engineFixture(t)
	s := rule("padded")
	s.PreRollSeconds, s.PostRollSeconds = 30, 60
	saveRule(t, m, s)
	var deadline time.Time
	original := m.startCapture
	m.startCapture = func(ctx context.Context, o CaptureOptions) (captureJob, error) {
		deadline = o.End
		return original(ctx, o)
	}
	*now = now.Add(time.Hour - 31*time.Second)
	tick(m)
	if *count != 0 {
		t.Fatal("started before pre-roll")
	}
	*now = now.Add(time.Second)
	tick(m)
	row := m.Snapshot().Recordings[0]
	if *count != 1 || parseTime(row.PlannedStart).Format("15:04:05") != "10:00:00" || row.captureStart().Format("15:04:05") != "09:59:30" || deadline.Format("15:04:05") != "11:01:00" {
		t.Fatalf("wrong padded window: %+v end=%s", row, deadline)
	}
	// Editing the source rule cannot change an active capture or its remainder.
	s.PreRollSeconds, s.PostRollSeconds = 0, 0
	s.EndTime = "12:00"
	saveRule(t, m, s)
	*now = time.Date(2026, 1, 5, 11, 0, 15, 0, time.UTC)
	m.lastNow = *now
	m.mu.Lock()
	m.requestStop(m.jobs[row.ID], "test interruption", true)
	m.mu.Unlock()
	until := time.Now().Add(time.Second)
	for *count < 2 && time.Now().Before(until) {
		tick(m)
		time.Sleep(time.Millisecond)
	}
	if *count != 2 || deadline.Format("15:04:05") != "11:01:00" {
		t.Fatalf("post-roll resume lost frozen timing: count=%d end=%s", *count, deadline)
	}
	for _, r := range m.Snapshot().Recordings {
		if r.ParentID == row.ID && (r.PlannedEnd != row.PlannedEnd || r.CaptureEnd != row.CaptureEnd) {
			t.Fatalf("remainder timing changed: %+v", r)
		}
	}
	*now = deadline
	m.lastNow = *now
	tick(m)
	waitFinished(t, m)
}

func TestPreRollStartsOnDayBeforeProgramAndRespectsConcurrency(t *testing.T) {
	m, now, count := engineFixture(t)
	s := rule("midnight")
	s.Kind, s.Date, s.StartTime, s.EndTime = "once", "2026-01-06", "00:00", "00:01"
	s.PreRollSeconds = 60
	saveRule(t, m, s)
	*now = time.Date(2026, 1, 5, 23, 59, 0, 0, time.UTC)
	tick(m)
	if *count != 1 {
		t.Fatal("tomorrow's pre-roll did not start")
	}
	settings := m.Snapshot().Settings
	settings.Concurrency = 1
	if err := m.SetSettings(m.Snapshot().Revision, settings); err != nil {
		t.Fatal(err)
	}
	s.ID = "overlap"
	saveRule(t, m, s)
	tick(m)
	if *count != 1 || len(m.Snapshot().Recordings) != 2 {
		t.Fatal("padding bypassed concurrency")
	}
	for _, r := range m.Snapshot().Recordings {
		if r.ScheduleID == "overlap" && (r.Status != "missed" || !strings.Contains(r.Reason, "limit")) {
			t.Fatalf("overlap not explained: %+v", r)
		}
	}
}
func waitFinished(t *testing.T, m *Manager) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		tick(m)
		if m.Snapshot().ActiveCount == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("fake capture did not finalize")
}

func TestEngineLazyFolderRevisionAndCopies(t *testing.T) {
	m, _, _ := engineFixture(t)
	s := m.Snapshot()
	if _, err := os.Stat(s.Settings.Folder); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("media folder created on Open: %v", err)
	}
	if s.Schedules == nil || s.Recordings == nil {
		t.Fatal("collections must serialize as arrays")
	}
	r := rule("weekly")
	saveRule(t, m, r)
	s = m.Snapshot()
	s.Schedules[0].Weekdays[0] = 4
	if m.Snapshot().Schedules[0].Weekdays[0] != 1 {
		t.Fatal("snapshot aliases manager")
	}
	old := m.Snapshot()
	settings := old.Settings
	settings.StorageCapBytes++
	if err := m.SetSettings(old.Revision-1, settings); err == nil {
		t.Fatal("stale settings accepted")
	}
	if m.Snapshot().Revision != old.Revision {
		t.Fatal("stale mutation changed revision")
	}
	b, _ := json.Marshal(m.Snapshot())
	if !strings.Contains(string(b), `"recordings":[]`) {
		t.Fatal(string(b))
	}
}

func TestEngineRemainderDuplicateAndSnapshot(t *testing.T) {
	m, now, count := engineFixture(t)
	saveRule(t, m, rule("weekly"))
	*now = now.Add(90 * time.Minute)
	tick(m)
	s := m.Snapshot()
	if *count != 1 || s.ActiveCount != 1 || s.Recordings[0].Reason == "" {
		t.Fatalf("late remainder: %+v count=%d", s, *count)
	}
	r := rule("weekly")
	r.StationName = "Edited"
	r.EndTime = "12:00"
	r.Enabled = false
	saveRule(t, m, r)
	s = m.Snapshot()
	if s.Recordings[0].StationName != "Station" || parseTime(s.Recordings[0].PlannedEnd).Hour() != 11 {
		t.Fatal("schedule edit altered running job")
	}
	*now = now.Add(-time.Hour)
	tick(m)
	*now = now.Add(time.Hour)
	tick(m)
	if len(m.state.Seen) != 1 || *count > 2 {
		t.Fatal("clock jump duplicated occurrence identity")
	}
	activeID := ""
	for _, r := range m.Snapshot().Recordings {
		if r.Status == "recording" {
			activeID = r.ID
		}
	}
	if err := m.StopRecording(m.Snapshot().Revision, activeID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	if m.Snapshot().Recordings[0].Status != "partial" {
		t.Fatal("manual stop was not partial")
	}
}

func TestEngineMissedAndConcurrency(t *testing.T) {
	m, now, count := engineFixture(t)
	for _, id := range []string{"a", "b", "c", "d"} {
		saveRule(t, m, rule(id))
	}
	*now = now.Add(time.Hour)
	tick(m)
	s := m.Snapshot()
	if s.ActiveCount != 3 || *count != 3 || len(s.Recordings) != 4 {
		t.Fatalf("overlap %+v count=%d", s, *count)
	}
	missed := 0
	for _, r := range s.Recordings {
		if r.Status == "missed" {
			missed++
		}
	}
	if missed != 1 {
		t.Fatal("limit occurrence not missed")
	}
	m2, now2, count2 := engineFixture(t)
	saveRule(t, m2, rule("elapsed"))
	*now2 = now2.Add(3 * time.Hour)
	tick(m2)
	if *count2 != 0 || m2.Snapshot().Recordings[0].Status != "missed" {
		t.Fatal("elapsed interval launched encoder")
	}
}

func TestEngineStorageFolderAndSafeDeletion(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	r := m.Snapshot().Recordings[0]
	if err := m.DeleteRecording(m.Snapshot().Revision, r.ID); err == nil {
		t.Fatal("deleted active recording")
	}
	settings := m.Snapshot().Settings
	settings.Folder = filepath.Join(t.TempDir(), "future")
	if err := m.SetSettings(m.Snapshot().Revision, settings); err != nil {
		t.Fatal(err)
	}
	if err := m.StopRecording(m.Snapshot().Revision, r.ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	retained, path, err := m.RecordingPath(r.ID)
	if err != nil {
		t.Fatal(err)
	}
	if retained.Folder == settings.Folder || m.Snapshot().UsedBytes != 40 {
		t.Fatal("folder edit moved or lost old media")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/etc/passwd", path); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.RecordingPath(r.ID); err == nil {
		t.Fatal("symlink was accepted")
	}
	if err := m.DeleteRecording(m.Snapshot().Revision, r.ID); err == nil {
		t.Fatal("symlink deletion accepted")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("safe"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.DeleteRecording(m.Snapshot().Revision, r.ID); err != nil {
		t.Fatal(err)
	}
	if len(m.Snapshot().Recordings) != 0 {
		t.Fatal("deleted row retained")
	}
}

func TestEngineCapReserveAndMonitoring(t *testing.T) {
	for _, mode := range []string{"cap", "reserve", "statfs"} {
		t.Run(mode, func(t *testing.T) {
			m, now, _ := engineFixture(t)
			saveRule(t, m, rule("a"))
			*now = now.Add(time.Hour)
			tick(m)
			if mode == "cap" {
				s := m.Snapshot().Settings
				s.StorageCapBytes = 20
				if err := m.SetSettings(m.Snapshot().Revision, s); err != nil {
					t.Fatal(err)
				}
			} else if mode == "reserve" {
				m.freeBytes = func(string) (int64, error) { return 0, nil }
			} else {
				m.freeBytes = func(string) (int64, error) { return 0, errors.New("fixture") }
			}
			tick(m)
			waitFinished(t, m)
			r := m.Snapshot().Recordings[0]
			if r.Status != "partial" || r.Reason == "" {
				t.Fatalf("storage stop %+v", r)
			}
		})
	}
}

func TestEngineFailedWriteNoPublication(t *testing.T) {
	m, _, _ := engineFixture(t)
	old := m.Snapshot()
	dir := filepath.Dir(m.path)
	if err := os.Rename(dir, dir+".saved"); err != nil {
		t.Fatal(err)
	}
	s := old.Settings
	s.StorageCapBytes++
	err := m.SetSettings(old.Revision, s)
	if err == nil {
		t.Fatal("write unexpectedly succeeded")
	}
	got := m.Snapshot()
	if got.Revision != old.Revision || got.Settings != old.Settings {
		t.Fatal("failed write published state")
	}
	if err := os.Rename(dir+".saved", dir); err != nil {
		t.Fatal(err)
	}
}

func TestEngineCorruptIndexIsReadOnly(t *testing.T) {
	base := t.TempDir()
	path := filepath.Join(base, "recordings.json")
	bad := []byte(`{"version":1,"schedules":`)
	if err := os.WriteFile(path, bad, 0600); err != nil {
		t.Fatal(err)
	}
	m, err := Open(Config{DataDir: base, DefaultFolder: filepath.Join(base, "music"), PollInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	s := m.Snapshot()
	if s.Available || s.Error == "" {
		t.Fatal("corrupt index accepted")
	}
	if err := m.SetSettings(s.Revision, s.Settings); err == nil {
		t.Fatal("corrupt index allowed writes")
	}
	got, _ := os.ReadFile(path)
	if string(got) != string(bad) {
		t.Fatal("corrupt data overwritten")
	}
}

func TestEngineInputBounds(t *testing.T) {
	m, _, _ := engineFixture(t)
	for _, change := range []func(*Schedule){func(s *Schedule) { s.ID = "../bad" }, func(s *Schedule) { s.Weekdays = []int{1, 1} }, func(s *Schedule) { s.EndTime = "10:00" }, func(s *Schedule) { s.EndTime = "23:00" }, func(s *Schedule) { s.Timezone = "Local" }, func(s *Schedule) { s.StreamURL = "file:///etc/passwd" }, func(s *Schedule) { s.Label = strings.Repeat("x", 257) }} {
		r := rule("a")
		change(&r)
		if err := m.UpsertSchedule(m.Snapshot().Revision, r); err == nil {
			t.Fatalf("invalid rule accepted %+v", r)
		}
	}
	settings := m.Snapshot().Settings
	settings.Folder = "relative"
	if err := m.SetSettings(m.Snapshot().Revision, settings); err == nil {
		t.Fatal("relative path accepted")
	}
	m.mu.Lock()
	for i := 0; i < maxRecordings; i++ {
		m.state.Recordings = append(m.state.Recordings, entry{})
	}
	err := m.startLocked(rule("x"), occurrence{Key: "x:2026-01-05", Start: time.Now(), End: time.Now()}, time.Now(), "")
	m.state.Recordings = []entry{}
	m.mu.Unlock()
	if err == nil {
		t.Fatal("history bound accepted")
	}
}

func TestEngineCloseReapsAndReloadSuppresses(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	s := m.Snapshot()
	if s.ActiveCount != 0 || s.Recordings[0].Status != "partial" {
		t.Fatalf("Close did not persist partial %+v", s)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if len(m2.state.Seen) != 1 {
		t.Fatal("occurrence ledger lost")
	}
	// A partial close retains explicit resume intent; its remainder is linked,
	// while the original occurrence identity remains exactly one ledger entry.
	m2.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m2.dependencyError = ""
	m2.freeBytes = m.freeBytes
	tick(m2)
	rows := m2.Snapshot().Recordings
	if len(rows) != 2 || len(m2.state.Seen) != 1 {
		t.Fatalf("resume rows %+v", rows)
	}
	linked := false
	for _, r := range rows {
		if r.ParentID == s.Recordings[0].ID {
			linked = true
		}
	}
	if !linked {
		t.Fatal("remainder omitted parent link")
	}
}

func TestEngineActiveUnlinkStopsAndAccounts(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	r := m.Snapshot().Recordings[0]
	if err := os.Remove(filepath.Join(r.Folder, r.Filename)); err != nil {
		t.Fatal(err)
	}
	tick(m)
	waitFinished(t, m)
	s := m.Snapshot()
	if s.ActiveCount != 0 || s.Recordings[0].Status != "missing" || s.UsedBytes != 0 {
		t.Fatalf("unlinked active capture %+v", s)
	}
}

func TestEngineFinalizationCannotReplaceExistingFile(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	r := m.Snapshot().Recordings[0]
	final := filepath.Join(r.Folder, r.ID+".opus")
	if err := os.WriteFile(final, []byte("existing retained file"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := m.StopRecording(m.Snapshot().Revision, r.ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	b, err := os.ReadFile(final)
	if err != nil || string(b) != "existing retained file" {
		t.Fatalf("final audio was replaced: %q %v", b, err)
	}
	if m.Snapshot().Recordings[0].Filename != r.Filename {
		t.Fatal("unfinalized partial was lost")
	}
	if err := m.DeleteRecording(m.Snapshot().Revision, r.ID); err != nil {
		t.Fatal(err)
	}
	b, err = os.ReadFile(final)
	if err != nil || string(b) != "existing retained file" {
		t.Fatal("deleting the partial removed an unrelated final-name collision", err)
	}
}

func TestEnginePostRenameSyncFailureFailsClosedAtDiskRevision(t *testing.T) {
	m, _, _ := engineFixture(t)
	old := m.Snapshot()
	m.persist = func(path string, s diskState) error {
		if err := persistState(path, s); err != nil {
			return err
		}
		return committedWriteError{errors.New("fixture directory sync failure")}
	}
	settings := old.Settings
	settings.StorageCapBytes++
	if err := m.SetSettings(old.Revision, settings); err == nil {
		t.Fatal("durability failure hidden")
	}
	disk, err := loadState(m.path)
	if err != nil {
		t.Fatal(err)
	}
	got := m.Snapshot()
	if got.Available || got.Revision != disk.Revision || got.Settings != disk.Settings {
		t.Fatalf("memory diverged from replaced disk %+v", got)
	}
	if err := m.SetSettings(got.Revision, old.Settings); err == nil {
		t.Fatal("write allowed after uncertain durability")
	}
}

func TestEngineMissingOutputRecoveryAndTransactionalResume(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	s := m.state.clone()
	r := &s.Recordings[0]
	if err := removeManaged(*r); err != nil {
		t.Fatal(err)
	}
	r.Status = "recording"
	r.Resume = false
	r.Filename = r.ID + ".partial"
	if err := persistState(m.path, s); err != nil {
		t.Fatal(err)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if !m2.state.Recordings[0].Resume || m2.state.Recordings[0].Status != "missing" {
		t.Fatal("missing output lost interrupted intent")
	}
	starts := 0
	m2.dependencyError = ""
	m2.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		starts++
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m2.freeBytes = m.freeBytes
	m2.persist = func(string, diskState) error { return errors.New("fixture disk failure") }
	tick(m2)
	if starts != 0 || len(m2.state.Recordings) != 1 || !m2.state.Recordings[0].Resume {
		t.Fatal("failed successor commit consumed durable resume intent")
	}
	// A storage failure stops the manager until the location is repaired and
	// reopened; its durable resume intent must survive that restart.
	if err := m2.Close(); err != nil {
		t.Fatal(err)
	}
	m3, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m3.Close()
	m3.startCapture, m3.freeBytes, m3.dependencyError = m2.startCapture, m2.freeBytes, ""
	tick(m3)
	if starts != 1 || len(m3.state.Recordings) != 2 || m3.state.Recordings[0].Resume {
		t.Fatal("successor was not atomically linked")
	}
}

func TestEngineCheckpointsDoNotInvalidateEditorsAndIdleDoesNotWrite(t *testing.T) {
	m, now, _ := engineFixture(t)
	calls := 0
	m.persist = func(path string, s diskState) error { calls++; return persistState(path, s) }
	*now = now.Add(10 * time.Minute)
	tick(m)
	if calls != 0 {
		t.Fatal("idle engine wrote a checkpoint")
	}
	saveRule(t, m, rule("a"))
	revision := m.Snapshot().Revision
	*now = now.Add(2 * time.Minute)
	tick(m)
	if m.Snapshot().Revision != revision {
		t.Fatal("housekeeping invalidated an editor")
	}
	if calls != 2 {
		t.Fatalf("mutation and checkpoint writes=%d", calls)
	}
}

func TestEngineDisabledIntervalsDoNotBackfill(t *testing.T) {
	m, now, count := engineFixture(t)
	s := rule("a")
	s.Enabled = false
	saveRule(t, m, s)
	*now = now.Add(8 * 24 * time.Hour)
	tick(m)
	s.Enabled = true
	saveRule(t, m, s)
	tick(m)
	if *count != 0 || len(m.Snapshot().Recordings) != 0 {
		t.Fatal("disabled intervals were backfilled")
	}
}

func TestEngineDependencyUnavailableStillAllowsConfiguration(t *testing.T) {
	base := t.TempDir()
	m, err := Open(Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "music"), FFmpeg: filepath.Join(base, "absent"), PollInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	s := m.Snapshot()
	if s.Available || !strings.Contains(s.Error, "encoder unavailable") {
		t.Fatalf("missing dependency readiness %+v", s)
	}
	settings := s.Settings
	settings.StorageCapBytes++
	if err := m.SetSettings(s.Revision, settings); err != nil {
		t.Fatal("dependency failure blocked configuration", err)
	}
}

func TestEngineRecoveryProbesFinalNameAfterInterruptedPublish(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	s := m.state.clone()
	s.Recordings[0].Status = "recording"
	s.Recordings[0].Resume = false
	s.Recordings[0].Filename = s.Recordings[0].ID + ".partial"
	if err := persistState(m.path, s); err != nil {
		t.Fatal(err)
	}
	probe := filepath.Join(t.TempDir(), "probe")
	script := "#!/bin/sh\nprintf '%s\\n' '{\"streams\":[{\"codec_name\":\"opus\",\"channels\":1}],\"format\":{\"duration\":\"5\",\"format_name\":\"ogg\"}}'\n"
	if err := os.WriteFile(probe, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	config := m.config
	config.FFprobe = probe
	m2, err := Open(config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	r := m2.state.Recordings[0]
	if r.Status != "partial" || r.DurationSeconds != 5 || r.Filename != r.ID+".opus" || !r.Resume {
		t.Fatalf("recovered final-name output %+v", r)
	}
}

func TestCrashRecoveryDoesNotSubstituteRestartForCaptureEnd(t *testing.T) {
	for _, knownEnd := range []bool{false, true} {
		for _, expired := range []bool{false, true} {
			t.Run(fmt.Sprintf("known=%v/expired=%v", knownEnd, expired), func(t *testing.T) {
				m, now, _ := engineFixture(t)
				saveRule(t, m, rule("crash-time"))
				*now = now.Add(time.Hour)
				tick(m)
				if err := m.Close(); err != nil {
					t.Fatal(err)
				}
				s := m.state.clone()
				s.Recordings[0].Status = "recording"
				s.Recordings[0].Resume = false
				want := ""
				if knownEnd {
					want = timestamp(now.Add(5 * time.Second))
				}
				s.Recordings[0].EndedAt = want
				if err := persistState(m.path, s); err != nil {
					t.Fatal(err)
				}
				probe := filepath.Join(t.TempDir(), "probe")
				script := "#!/bin/sh\nprintf '%s\\n' '{\"streams\":[{\"codec_name\":\"opus\",\"channels\":1}],\"format\":{\"duration\":\"5\",\"format_name\":\"ogg\"}}'\n"
				if err := os.WriteFile(probe, []byte(script), 0700); err != nil {
					t.Fatal(err)
				}
				*now = now.Add(30 * time.Second)
				if expired {
					*now = now.Add(2 * time.Hour)
				}
				config := m.config
				config.FFprobe = probe
				reopened, err := Open(config)
				if err != nil {
					t.Fatal(err)
				}
				defer reopened.Close()
				recovered := reopened.Snapshot().Recordings[0]
				if recovered.EndedAt != want {
					t.Fatalf("recovery invented an end: got %q, want %q (restart %s)", recovered.EndedAt, want, *now)
				}
				if recovered.Status != "partial" || !recovered.Playable {
					t.Fatalf("end-time fix lost retained audio: %+v", recovered)
				}
			})
		}
	}
}

func TestEngineDeletionIntentSurvivesFinalIndexFailure(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	r := m.Snapshot().Recordings[0]
	if err := m.StopRecording(m.Snapshot().Revision, r.ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	calls := 0
	m.persist = func(path string, s diskState) error {
		calls++
		if calls == 2 {
			return errors.New("fixture deletion publication failure")
		}
		return persistState(path, s)
	}
	if err := m.DeleteRecording(m.Snapshot().Revision, r.ID); err == nil {
		t.Fatal("final publication failure hidden")
	}
	if len(m.state.Recordings) != 1 || !m.state.Recordings[0].Deleting {
		t.Fatal("durable deletion intent lost")
	}
	m.persist = persistState
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if len(m2.Snapshot().Recordings) != 0 {
		t.Fatal("deletion intent did not reconcile on restart")
	}
}

func TestEngineUnwritableFolderAndNewCurrentInterval(t *testing.T) {
	m, now, count := engineFixture(t)
	settings := m.Snapshot().Settings
	if err := os.WriteFile(settings.Folder, []byte("folder is a file"), 0600); err != nil {
		t.Fatal(err)
	}
	*now = now.Add(90 * time.Minute)
	saveRule(t, m, rule("a"))
	tick(m)
	s := m.Snapshot()
	if *count != 0 || len(s.Recordings) != 1 || s.Recordings[0].Status != "missed" || !strings.Contains(s.Recordings[0].Reason, "folder") {
		t.Fatalf("bad folder %+v", s)
	}
}

func TestEngineBoundedIndexAndCollection(t *testing.T) {
	path := filepath.Join(t.TempDir(), "recordings.json")
	if err := os.WriteFile(path, []byte(strings.Repeat(" ", maxIndexBytes+1)), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadState(path); err == nil {
		t.Fatal("oversized index accepted")
	}
	m, _, _ := engineFixture(t)
	m.mu.Lock()
	for i := 0; i < maxSchedules; i++ {
		m.state.Schedules = append(m.state.Schedules, rule("existing"))
	}
	m.mu.Unlock()
	if err := m.UpsertSchedule(m.Snapshot().Revision, rule("overflow")); err == nil {
		t.Fatal("schedule limit accepted")
	}
	m.mu.Lock()
	m.state.Schedules = []Schedule{}
	m.mu.Unlock()
}

func TestEnginePeriodicLoopConcurrentReadersAndClose(t *testing.T) {
	var clock atomic.Int64
	clock.Store(time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC).Unix())
	base := t.TempDir()
	m, err := Open(Config{DataDir: filepath.Join(base, "data"), DefaultFolder: filepath.Join(base, "music"), PollInterval: 5 * time.Millisecond, Now: func() time.Time { return time.Unix(clock.Load(), 0) }})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	m.mu.Lock()
	m.dependencyError = ""
	m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m.freeBytes = func(string) (int64, error) { return 1 << 40, nil }
	m.mu.Unlock()
	saveRule(t, m, rule("a"))
	clock.Add(3600)
	deadline := time.Now().Add(time.Second)
	for m.Snapshot().ActiveCount != 1 {
		if time.Now().After(deadline) {
			t.Fatal("periodic scheduler did not start capture")
		}
		time.Sleep(time.Millisecond)
	}
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 20; n++ {
				s := m.Snapshot()
				settings := s.Settings
				_ = m.SetSettings(s.Revision, settings)
			}
		}()
	}
	wg.Wait()
	if len(m.updates) > 1 {
		t.Fatal("updates did not coalesce")
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	if m.Snapshot().ActiveCount != 0 {
		t.Fatal("periodic capture survived Close")
	}
}

func TestLedgerCompactionKeepsRecentIdentitiesAndBackwardClockSafe(t *testing.T) {
	m, now, count := engineFixture(t)
	saveRule(t, m, rule("weekly"))
	highWater := now.AddDate(0, 0, 15)
	m.mu.Lock()
	m.state.Cursor = timestamp(highWater)
	for i := 0; i < maxOccurrences; i++ {
		m.state.Seen[fmt.Sprintf("old%d:2000-01-01", i)] = true
	}
	recent := "weekly:" + highWater.AddDate(0, 0, -2).Format("2006-01-02")
	m.state.Seen[recent] = true
	revision := m.state.Revision
	compactErr := m.compactLocked()
	valid := len(m.state.Seen) == 1 && m.state.Seen[recent] && m.state.Revision == revision
	m.mu.Unlock()
	if compactErr != nil {
		t.Fatal(compactErr)
	}
	if !valid {
		t.Fatal("compaction lost recent dedupe or invalidated an editor")
	}
	// The old Monday interval is no longer in Seen. Moving the wall clock
	// backward still cannot re-record it because the checkpoint never retreats.
	*now = now.Add(time.Hour)
	tick(m)
	if *count != 0 || len(m.Snapshot().Recordings) != 0 {
		t.Fatal("clock rollback recaptured an expired identity")
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	disk, err := loadState(m.path)
	if err != nil || parseTime(disk.Cursor).Before(highWater) {
		t.Fatal("Close moved high-water checkpoint backward", err)
	}
}

func TestLongUnavailablePeriodUsesBoundedMissedSummary(t *testing.T) {
	m, now, count := engineFixture(t)
	saveRule(t, m, rule("weekly"))
	*now = now.AddDate(0, 3, 0)
	tick(m)
	s := m.Snapshot()
	if *count != 0 {
		t.Fatal("started a capture for an old unavailable interval")
	}
	summaries := 0
	for _, r := range s.Recordings {
		if strings.Contains(r.Reason, "older missed intervals grouped") {
			summaries++
		}
	}
	if summaries != 1 || len(s.Recordings) > 4 {
		t.Fatalf("unbounded or missing catch-up summary: %+v", s.Recordings)
	}
}

func TestRetainedAudioAvailabilityRecoversWhenFolderReturns(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	row := m.Snapshot().Recordings[0]
	path := filepath.Join(row.Folder, row.Filename)
	if err := os.Rename(path, path+".away"); err != nil {
		t.Fatal(err)
	}
	if snapshot := m.Snapshot(); snapshot.Recordings[0].Playable || snapshot.Recordings[0].Status != "missing" || snapshot.UsedBytes != 0 {
		t.Fatal("missing file was offered for playback")
	}
	if err := os.Rename(path+".away", path); err != nil {
		t.Fatal(err)
	}
	if snapshot := m.Snapshot(); !snapshot.Recordings[0].Playable || snapshot.UsedBytes == 0 {
		t.Fatal("returned audio remained unavailable")
	}
}

func TestUnexpectedStreamEndRetriesWithBoundedBackoff(t *testing.T) {
	m, now, count := engineFixture(t)
	m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		*count++
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		result := CaptureResult{Bytes: 40, DurationSeconds: 5, Err: errors.New("fixture disconnect")}
		return &finishedCapture{result: result, done: resultChannel(result)}, nil
	}
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	tick(m)
	if *count != 1 || m.Snapshot().ActiveCount != 0 {
		t.Fatal("first failure did not wait before retry")
	}
	*now = now.Add(time.Second)
	tick(m)
	tick(m)
	if *count != 2 {
		t.Fatal("first bounded retry missing")
	}
	*now = now.Add(time.Second)
	tick(m)
	if *count != 2 {
		t.Fatal("second retry ignored its backoff")
	}
	*now = now.Add(time.Second)
	tick(m)
	tick(m)
	if *count != 3 || m.Snapshot().ActiveCount != 0 {
		t.Fatal("retry count or cleanup incorrect")
	}
	*now = now.Add(30 * time.Second)
	tick(m)
	if *count != 3 {
		t.Fatal("retry budget allowed another encoder")
	}
	found := false
	for _, row := range m.Snapshot().Recordings {
		if strings.Contains(row.Reason, "retry limit") {
			found = true
		}
	}
	if !found {
		t.Fatal("retry exhaustion was not surfaced")
	}
}

func TestCaptureEndTimeSurvivesDelayedFinalization(t *testing.T) {
	for _, early := range []bool{true, false} {
		t.Run(fmt.Sprint(early), func(t *testing.T) {
			m, now, _ := engineFixture(t)
			saveRule(t, m, rule("timing"))
			*now = now.Add(time.Hour)
			start, end := *now, now.Add(time.Hour)
			capturedEnd := end
			if early {
				capturedEnd = end.Add(-10 * time.Second)
			}
			m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
				if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
					return nil, err
				}
				result := CaptureResult{Bytes: 40, DurationSeconds: 5, StartedAt: start, EndedAt: capturedEnd}
				return &finishedCapture{result: result, done: resultChannel(result)}, nil
			}
			tick(m)
			// The probe/poll finishes after the deadline, even though the stream
			// may have ended ten seconds early. No actual suspend occurred.
			*now = end.Add(3 * time.Second)
			m.lastNow = *now
			tick(m)
			row := m.Snapshot().Recordings[0]
			if parseTime(row.EndedAt) != capturedEnd {
				t.Fatalf("probe time replaced encoder end: got %s, want %s", row.EndedAt, capturedEnd)
			}
			want := "complete"
			if early {
				want = "partial"
			}
			if row.Status != want {
				t.Fatalf("ended early=%v: got %s, want %s (%s)", early, row.Status, want, row.Reason)
			}
			if m.state.Recordings[0].Resume {
				t.Fatal("expired interval retained retry intent")
			}
		})
	}
}

func TestCaptureStopTimeoutExplainsMissingTail(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("stalled"))
	*now = now.Add(time.Hour)
	end := now.Add(time.Hour)
	m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		result := CaptureResult{Bytes: 40, DurationSeconds: 5, EndedAt: end, Err: errCaptureStopTimeout}
		return &finishedCapture{result: result, done: resultChannel(result)}, nil
	}
	tick(m)
	*now = end.Add(time.Second)
	m.lastNow = *now
	tick(m)
	row := m.Snapshot().Recordings[0]
	if row.Status != "partial" || !strings.Contains(row.Reason, "ending audio may be missing") {
		t.Fatalf("stalled encoder did not explain its partial output: %+v", row)
	}
}

func TestReaderTimeoutRetainsFinalizedAudioAsPartial(t *testing.T) {
	for _, writerFailed := range []bool{false, true} {
		t.Run(fmt.Sprint(writerFailed), func(t *testing.T) {
			m, now, _ := engineFixture(t)
			saveRule(t, m, rule("stalled-reader"))
			*now = now.Add(time.Hour)
			m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
				if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
					return nil, err
				}
				result := CaptureResult{Bytes: 40, DurationSeconds: 5, EndedAt: now.Add(time.Hour), Err: errCaptureReaderTimeout}
				if writerFailed {
					result.Err = errors.Join(result.Err, errCaptureEncoderFailed)
				}
				return &finishedCapture{result: result, done: resultChannel(result)}, nil
			}
			tick(m)
			*now = now.Add(time.Hour + time.Second)
			m.lastNow = *now
			tick(m)
			row := m.Snapshot().Recordings[0]
			if row.Status != "partial" || strings.Contains(row.Reason, "saved audio was finalized") == writerFailed || !row.Playable {
				t.Fatalf("reader stall did not retain its finalized partial: %+v", row)
			}
		})
	}
}

func TestPersistenceFailureReapsActiveCapturesWithoutWaitingForShutdown(t *testing.T) {
	for _, afterRename := range []bool{false, true} {
		t.Run(fmt.Sprint(afterRename), func(t *testing.T) {
			m, now, _ := engineFixture(t)
			saveRule(t, m, rule("a"))
			*now = now.Add(time.Hour)
			tick(m)
			old := m.Snapshot()
			m.persist = func(path string, state diskState) error {
				if afterRename {
					if err := persistState(path, state); err != nil {
						return err
					}
					return committedWriteError{errors.New("fixture sync failure")}
				}
				return errors.New("fixture write failure")
			}
			settings := old.Settings
			settings.StorageCapBytes++
			if err := m.SetSettings(old.Revision, settings); err == nil {
				t.Fatal("write failure hidden")
			}
			deadline := time.Now().Add(time.Second)
			for m.Snapshot().ActiveCount != 0 {
				if time.Now().After(deadline) {
					t.Fatal("active capture survived durability failure")
				}
				time.Sleep(time.Millisecond)
			}
			if m.Snapshot().Available {
				t.Fatal("writes remained available after persistence failure")
			}
			disk, err := loadState(m.path)
			if err != nil || len(disk.Recordings) != 1 || disk.Recordings[0].Filename == "" {
				t.Fatal("recoverable file identity lost", err)
			}
		})
	}
}

func TestIndexCapacityStopsCapturesWithoutBlockingHistoryCleanup(t *testing.T) {
	m, now, _ := engineFixture(t)
	saveRule(t, m, rule("a"))
	*now = now.Add(time.Hour)
	tick(m)
	old := m.Snapshot()
	m.persist = func(string, diskState) error { return errIndexFull }
	settings := old.Settings
	settings.StorageCapBytes++
	if err := m.SetSettings(old.Revision, settings); !errors.Is(err, errIndexFull) {
		t.Fatal(err)
	}
	if !m.Snapshot().Available || m.Snapshot().Settings != old.Settings {
		t.Fatal("capacity rejection blocked cleanup or published settings")
	}
	m.persist = persistState
	waitFinished(t, m)
	row := m.Snapshot().Recordings[0]
	if err := m.DeleteRecording(m.Snapshot().Revision, row.ID); err != nil {
		t.Fatal("history could not be removed after capacity rejection", err)
	}
}

func TestOnceOutageAndNoRepeatAfterRestart(t *testing.T) {
	m, now, count := engineFixture(t)
	s := rule("single")
	s.Kind, s.Date, s.Weekdays = "once", "2026-01-05", nil
	saveRule(t, m, s)
	*now = now.Add(14 * 24 * time.Hour)
	tick(m)
	snap := m.Snapshot()
	if len(snap.Recordings) != 1 || snap.Recordings[0].Status != "missed" || *count != 0 {
		t.Fatalf("outage: %+v", snap.Recordings)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	tick(reopened)
	if got := reopened.Snapshot().Recordings; len(got) != 1 {
		t.Fatalf("repeated on restart: %+v", got)
	}
}

func TestStartNowAndPlaybackCheckpoint(t *testing.T) {
	m, _, count := engineFixture(t)
	station := rule("")
	rev := m.Snapshot().Revision
	if err := m.StartNow(rev+1, station, time.Minute); err == nil {
		t.Fatal("accepted stale revision")
	}
	if err := m.StartNow(rev, station, time.Second); err == nil {
		t.Fatal("accepted short duration")
	}
	if err := m.StartNow(rev, station, time.Minute); err != nil {
		t.Fatal(err)
	}
	snap := m.Snapshot()
	if len(snap.Schedules) != 0 || snap.ActiveCount != 1 || *count != 1 {
		t.Fatalf("start: %+v", snap)
	}
	id := snap.Recordings[0].ID
	if err := m.StopRecording(snap.Revision, id); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	snap = m.Snapshot()
	rev = snap.Revision
	if err := m.SetPlaybackPosition(id, 3); err != nil {
		t.Fatal(err)
	}
	if err := m.SetPlaybackPosition(id, math.NaN()); err == nil {
		t.Fatal("accepted NaN")
	}
	if err := m.SetPlaybackPosition(id, 100); err != nil {
		t.Fatal(err)
	}
	if got := m.Snapshot(); got.Revision != rev || got.Recordings[0].ResumePosition != 5 {
		t.Fatalf("checkpoint: %+v", got)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if got := reopened.Snapshot(); got.Recordings[0].ResumePosition != 5 {
		t.Fatalf("reload: %+v", got)
	}
}

func TestStartNowRespectsConcurrencyAndReserve(t *testing.T) {
	m, _, _ := engineFixture(t)
	settings := m.Snapshot().Settings
	settings.Concurrency = 1
	if err := m.SetSettings(m.Snapshot().Revision, settings); err != nil {
		t.Fatal(err)
	}
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Minute); err != nil {
		t.Fatal(err)
	}
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Minute); err != nil {
		t.Fatal(err)
	}
	snap := m.Snapshot()
	if snap.ActiveCount != 1 || len(snap.Recordings) != 2 || snap.Recordings[1].Status != "missed" {
		t.Fatalf("concurrency: %+v", snap)
	}
	m.freeBytes = func(string) (int64, error) { return 0, nil }
	if err := m.StopRecording(snap.Revision, snap.Recordings[0].ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Minute); err != nil {
		t.Fatal(err)
	}
	snap = m.Snapshot()
	found := false
	for _, r := range snap.Recordings {
		if r.Reason == "free-space reserve reached" {
			found = true
		}
	}
	if !found {
		t.Fatalf("reserve: %+v", snap.Recordings)
	}
}

func TestStartNowRetainsRemainderOnRestart(t *testing.T) {
	m, _, _ := engineFixture(t)
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Hour); err != nil {
		t.Fatal(err)
	}
	id := m.Snapshot().Recordings[0].ID
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	m2.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m2.dependencyError = ""
	m2.freeBytes = m.freeBytes
	tick(m2)
	snap := m2.Snapshot()
	linked := false
	for _, r := range snap.Recordings {
		if r.ParentID == id {
			linked = true
		}
	}
	if len(snap.Schedules) != 0 || !linked || snap.ActiveCount != 1 {
		t.Fatalf("recovery: %+v", snap)
	}
}

func TestLegacyIndexWithoutNewFields(t *testing.T) {
	m, _, _ := engineFixture(t)
	saveRule(t, m, rule("old"))
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Minute); err != nil {
		t.Fatal(err)
	}
	snap := m.Snapshot()
	if err := m.StopRecording(snap.Revision, snap.Recordings[0].ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(m.path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	for _, item := range doc["recordings"].([]any) {
		delete(item.(map[string]any), "resumePosition")
	}
	for _, item := range doc["schedules"].([]any) {
		delete(item.(map[string]any), "kind")
		delete(item.(map[string]any), "date")
	}
	raw, err = json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(m.path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	if got := m2.Snapshot(); !got.Available || len(got.Schedules) != 1 || got.Recordings[0].ResumePosition != 0 {
		t.Fatalf("legacy: %+v", got)
	}
}

func TestOnceCaptureDoesNotRepeatNextWeek(t *testing.T) {
	m, now, count := engineFixture(t)
	s := rule("single")
	s.Kind, s.Date, s.Weekdays = "once", "2026-01-05", nil
	saveRule(t, m, s)
	*now = now.Add(time.Hour)
	tick(m)
	snap := m.Snapshot()
	if *count != 1 || snap.ActiveCount != 1 {
		t.Fatalf("first: %+v", snap)
	}
	if err := m.StopRecording(snap.Revision, snap.Recordings[0].ID); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	*now = now.Add(7 * 24 * time.Hour)
	tick(m)
	if *count != 1 || len(m.Snapshot().Recordings) != 1 {
		t.Fatalf("one-time schedule repeated: %+v", m.Snapshot())
	}
}

func TestOnceMidnightGapLongOutagePreservesDate(t *testing.T) {
	m, now, count := engineFixture(t)
	*now = time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	m.mu.Lock()
	m.state.Cursor = timestamp(*now)
	m.lastNow = *now
	m.mu.Unlock()
	s := rule("santiago")
	s.Kind, s.Date, s.Timezone, s.StartTime, s.EndTime, s.Weekdays = "once", "2026-09-06", "America/Santiago", "01:30", "02:30", nil
	saveRule(t, m, s)
	*now = time.Date(2026, 9, 20, 0, 0, 0, 0, time.UTC)
	tick(m)
	rows := m.Snapshot().Recordings
	if *count != 0 || len(rows) != 1 || rows[0].Status != "missed" || rows[0].PlannedStart != "2026-09-06T04:30:00Z" {
		t.Fatalf("wrong missed occurrence: %+v", rows)
	}
}

func TestStartNowRetrySurvivesRestart(t *testing.T) {
	m, now, count := engineFixture(t)
	m.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		*count++
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		result := CaptureResult{Bytes: 40, DurationSeconds: 5, Err: errors.New("fixture disconnect")}
		return &finishedCapture{result: result, done: resultChannel(result)}, nil
	}
	if err := m.StartNow(m.Snapshot().Revision, rule(""), time.Hour); err != nil {
		t.Fatal(err)
	}
	tick(m)
	first := m.Snapshot().Recordings[0]
	if first.Status != "partial" || *count != 1 {
		t.Fatalf("initial failure: %+v", first)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	m2, err := Open(m.config)
	if err != nil {
		t.Fatal(err)
	}
	defer m2.Close()
	m2.startCapture = func(_ context.Context, o CaptureOptions) (captureJob, error) {
		*count++
		if err := os.WriteFile(o.Path, make([]byte, 40), 0600); err != nil {
			return nil, err
		}
		return &fakeCapture{done: make(chan CaptureResult, 1)}, nil
	}
	m2.dependencyError = ""
	m2.freeBytes = m.freeBytes
	tick(m2)
	if *count != 1 {
		t.Fatal("retry ignored persisted backoff")
	}
	*now = now.Add(time.Second)
	tick(m2)
	snap := m2.Snapshot()
	linked := false
	for _, r := range snap.Recordings {
		if r.ParentID == first.ID && r.ScheduleID == first.ScheduleID && r.StationID == first.StationID {
			linked = true
		}
	}
	if *count != 2 || !linked || len(snap.Schedules) != 0 || snap.ActiveCount != 1 {
		t.Fatalf("retry recovery: %+v", snap)
	}
}
