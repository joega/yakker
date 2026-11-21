package recording

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

type captureJob interface {
	Done() <-chan CaptureResult
	Stop()
}
type activeJob struct {
	capture  captureJob
	reason   string
	resume   bool
	stopping bool
}

type Manager struct {
	mu               sync.Mutex
	config           Config
	state            diskState
	path             string
	readOnly, closed bool
	err              string
	dependencyError  string
	updates          chan struct{}
	stop, done       chan struct{}
	closeOnce        sync.Once
	closeErr         error
	jobs             map[string]*activeJob
	lastNow          time.Time
	startCapture     func(context.Context, CaptureOptions) (captureJob, error)
	freeBytes        func(string) (int64, error)
	persist          func(string, diskState) error
}

func Open(config Config) (*Manager, error) {
	if config.Now == nil {
		config.Now = time.Now
	}
	if config.PollInterval <= 0 {
		config.PollInterval = time.Second
	}
	if config.StopGrace <= 0 {
		config.StopGrace = 3 * time.Second
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	if config.DataDir == "" {
		base := os.Getenv("XDG_DATA_HOME")
		if !filepath.IsAbs(base) {
			base = filepath.Join(home, ".local", "share")
		}
		config.DataDir = filepath.Join(base, "yakker")
	}
	if config.DefaultFolder == "" {
		config.DefaultFolder = filepath.Join(home, "Music", "Yakker")
	}
	if !filepath.IsAbs(config.DataDir) {
		return nil, errors.New("recording data directory must be absolute")
	}
	if config.FFmpeg == "" {
		config.FFmpeg = "ffmpeg"
	}
	if config.FFprobe == "" {
		config.FFprobe = "ffprobe"
	}
	m := &Manager{config: config, path: filepath.Join(config.DataDir, "recordings.json"), updates: make(chan struct{}, 1), stop: make(chan struct{}), done: make(chan struct{}), jobs: map[string]*activeJob{}, lastNow: config.Now()}
	m.startCapture = func(ctx context.Context, o CaptureOptions) (captureJob, error) { return StartCapture(ctx, o) }
	m.persist = persistState
	m.freeBytes = func(path string) (int64, error) {
		var s syscall.Statfs_t
		if err := syscall.Statfs(path, &s); err != nil {
			return 0, err
		}
		return int64(s.Bavail) * int64(s.Bsize), nil
	}
	m.state = diskState{Version: 1, Revision: 1, Settings: Settings{Folder: config.DefaultFolder, StorageCapBytes: 5 << 30, FreeSpaceReserveBytes: 1 << 30, Concurrency: 3}, Schedules: []Schedule{}, Recordings: []entry{}, Seen: map[string]bool{}, RuleFrom: map[string]string{}, Cursor: timestamp(m.lastNow)}
	if err = validateSettings(m.state.Settings); err != nil {
		return nil, err
	}
	loaded, loadErr := loadState(m.path)
	if loadErr == nil {
		m.state = loaded
	} else if !errors.Is(loadErr, os.ErrNotExist) {
		m.readOnly = true
		m.err = indexError(loadErr)
	} else {
		if err = os.MkdirAll(config.DataDir, 0700); err == nil {
			err = persistState(m.path, m.state)
		}
		if err != nil {
			m.readOnly = true
			m.err = indexError(err)
		}
	}
	if !m.readOnly {
		m.recoverLocked()
	}
	m.dependencyError = checkDependencies(config)
	go m.run()
	return m, nil
}

func (m *Manager) Updates() <-chan struct{} { return m.updates }
func (m *Manager) notify() {
	select {
	case m.updates <- struct{}{}:
	default:
	}
}
func (m *Manager) fail(err error) { m.err = err.Error(); m.notify() }
func (m *Manager) persistenceFailed(s diskState, err error) error {
	if errors.Is(err, errIndexFull) {
		// Capacity rejection happens before any disk replacement. Keep deletion
		// available so the user can make room, while stopping further media growth.
		for _, job := range m.jobs {
			m.requestStop(job, "recording history index is full", false)
		}
		m.fail(err)
		return err
	}
	var committed committedWriteError
	if errors.As(err, &committed) {
		m.state = s
	}
	m.readOnly = true
	m.fail(errors.New(err.Error() + ". Repair the metadata location and reopen the plugin"))
	// A recorder must not keep writing media once its durable transitions can
	// no longer be saved. Stop/reap in parallel without holding the state lock.
	jobs := make(map[string]*activeJob, len(m.jobs))
	captures := make([]captureJob, 0, len(m.jobs))
	for id, job := range m.jobs {
		jobs[id] = job
		captures = append(captures, job.capture)
		job.stopping = true
	}
	if len(jobs) > 0 {
		go func() {
			var wg sync.WaitGroup
			for _, capture := range captures {
				wg.Add(1)
				go func(c captureJob) { defer wg.Done(); c.Stop() }(capture)
			}
			wg.Wait()
			m.mu.Lock()
			defer m.mu.Unlock()
			for id, job := range jobs {
				if m.jobs[id] == job {
					delete(m.jobs, id)
				}
			}
			m.notify()
		}()
	}
	return err
}
func (m *Manager) commit(s diskState) error {
	s.Revision = m.state.Revision + 1
	if err := m.persist(m.path, s); err != nil {
		return m.persistenceFailed(s, err)
	}
	m.state = s
	m.err = ""
	m.notify()
	return nil
}
func (m *Manager) writable(revision int64) error {
	if m.closed {
		return errors.New("recording manager is closed")
	}
	if m.readOnly {
		return errors.New(m.err)
	}
	if revision != m.state.Revision {
		return errors.New("recording state changed; refresh and try again")
	}
	return nil
}

func (m *Manager) Snapshot() Snapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	s := Snapshot{Revision: m.state.Revision, Settings: m.state.Settings, Schedules: []Schedule{}, Recordings: []Recording{}, Available: !m.readOnly && !m.closed && m.dependencyError == "", Error: m.err, ActiveCount: len(m.jobs), LocalTimezone: machineTimezone()}
	if s.Error == "" {
		s.Error = m.dependencyError
	}
	for _, r := range m.state.Schedules {
		r.Weekdays = append([]int{}, r.Weekdays...)
		s.Schedules = append(s.Schedules, preview(r, m.config.Now()))
	}
	for _, r := range m.state.Recordings {
		rec := r.Recording
		rec.Playable = false
		if info, _, err := managedInfo(r); err == nil {
			rec.Bytes = info.Size()
			s.UsedBytes += info.Size()
			rec.Playable = r.Status != "recording" && r.DurationSeconds > 0 && info.Size() > 0
			if r.Status == "missing" && rec.Playable {
				rec.Status = "partial"
				rec.Reason = "Retained audio is available again"
			}
		} else if r.Filename != "" && (r.Status == "complete" || r.Status == "partial" || r.Status == "missing") {
			rec.Status, rec.Bytes, rec.Reason = "missing", 0, "Recording audio is currently unavailable"
		}
		if r.Status == "recording" && m.readOnly && m.jobs[r.ID] == nil {
			rec.Status = "partial"
			rec.Reason = "Capture stopped because recording metadata could not be saved"
		}
		s.Recordings = append(s.Recordings, rec)
	}
	sort.SliceStable(s.Recordings, func(i, j int) bool {
		a, b := s.Recordings[i], s.Recordings[j]
		ta, tb := a.StartedAt, b.StartedAt
		if ta == "" {
			ta = a.PlannedStart
		}
		if tb == "" {
			tb = b.PlannedStart
		}
		return parseTime(ta).After(parseTime(tb))
	})
	return s
}

func (m *Manager) SetSettings(revision int64, settings Settings) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	if err := validateSettings(settings); err != nil {
		return err
	}
	s := m.state.clone()
	s.Settings = settings
	return m.commit(s)
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("system random source unavailable")
	}
	return hex.EncodeToString(b[:])
}

func (m *Manager) UpsertSchedule(revision int64, schedule Schedule) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	if schedule.ID == "" {
		schedule.ID = newID()
	}
	if schedule.Timezone == "" {
		schedule.Timezone = machineTimezone()
	}
	if err := validateSchedule(schedule); err != nil {
		return err
	}
	schedule.Weekdays = append([]int{}, schedule.Weekdays...)
	sort.Ints(schedule.Weekdays)
	schedule.NextStart = ""
	schedule.NextEnd = ""
	s := m.state.clone()
	found := false
	for i, r := range s.Schedules {
		if r.ID == schedule.ID {
			s.Schedules[i] = schedule
			found = true
			break
		}
	}
	if !found {
		if len(s.Schedules) >= maxSchedules {
			return boundsError("schedule", maxSchedules)
		}
		s.Schedules = append(s.Schedules, schedule)
		s.RuleFrom[schedule.ID] = timestamp(m.config.Now())
	}
	// An edit takes effect from now; re-enabling a rule must not backfill the
	// intervals during which it was disabled. Already running jobs own snapshots.
	s.RuleFrom[schedule.ID] = timestamp(m.config.Now())
	return m.commit(s)
}

// StartNow starts an independent capture without adding a schedule.
func (m *Manager) StartNow(revision int64, station Schedule, duration time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	if duration < time.Minute || duration > 12*time.Hour {
		return errors.New("recordings must last between 1 minute and 12 hours")
	}
	if !identifier.MatchString(station.StationID) || !textOK(station.StationName, 256) || strings.TrimSpace(station.StationName) == "" || !textOK(station.Label, 256) || !validStreamURL(station.StreamURL) {
		return errors.New("invalid recording station")
	}
	station.ID = newID()
	now := m.config.Now()
	return m.startLocked(station, occurrence{Key: station.ID + ":" + now.UTC().Format("2006-01-02"), Start: now, End: now.Add(duration)}, now, "")
}

// SetPlaybackPosition checkpoints progress without invalidating editing drafts.
func (m *Manager) SetPlaybackPosition(id string, seconds float64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.closed {
		return errors.New("recording manager is closed")
	}
	if m.readOnly {
		return errors.New(m.err)
	}
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return errors.New("invalid playback position")
	}
	s := m.state.clone()
	for i := range s.Recordings {
		r := &s.Recordings[i]
		if r.ID != id {
			continue
		}
		if r.Deleting || r.Status == "recording" {
			return errors.New("recording is not available for playback")
		}
		seconds = math.Max(0, math.Min(seconds, r.DurationSeconds))
		if r.ResumePosition == seconds {
			return nil
		}
		r.ResumePosition = seconds
		if err := m.checkpointLocked(s); err != nil {
			return err
		}
		m.notify()
		return nil
	}
	return errors.New("recording not found")
}

func (m *Manager) DeleteSchedule(revision int64, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	s := m.state.clone()
	for i, r := range s.Schedules {
		if r.ID == id {
			s.Schedules = append(s.Schedules[:i], s.Schedules[i+1:]...)
			delete(s.RuleFrom, id)
			return m.commit(s)
		}
	}
	return errors.New("schedule not found")
}

func (m *Manager) StopRecording(revision int64, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	job, ok := m.jobs[id]
	if !ok {
		return errors.New("recording is not active")
	}
	s := m.state.clone()
	for i := range s.Recordings {
		if s.Recordings[i].ID == id {
			s.Recordings[i].Reason = "stopped by user"
			s.Recordings[i].Resume = false
		}
	}
	if err := m.commit(s); err != nil {
		return err
	}
	m.requestStop(job, "stopped by user", false)
	return nil
}

func (m *Manager) DeleteRecording(revision int64, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.writable(revision); err != nil {
		return err
	}
	if _, ok := m.jobs[id]; ok {
		return errors.New("stop an active recording before deleting it")
	}
	s := m.state.clone()
	for i, r := range s.Recordings {
		if r.ID == id {
			s.Recordings[i].Deleting = true
			if err := m.commit(s); err != nil {
				return err
			}
			if err := removeManaged(r); err != nil {
				m.fail(err)
				return err
			}
			s = m.state.clone()
			s.Recordings = append(s.Recordings[:i], s.Recordings[i+1:]...)
			return m.commit(s)
		}
	}
	return errors.New("recording not found")
}

func (m *Manager) RecordingPath(id string) (Recording, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, r := range m.state.Recordings {
		if r.ID == id {
			if r.Deleting || r.Status == "recording" {
				return r.Recording, "", errors.New("recording is not available for playback")
			}
			_, path, err := managedInfo(r)
			if err != nil {
				return r.Recording, "", errors.New("recording audio is missing or unsafe")
			}
			return r.Recording, path, nil
		}
	}
	return Recording{}, "", errors.New("recording not found")
}

func (m *Manager) requestStop(job *activeJob, reason string, resume bool) {
	if job.stopping {
		if !resume && reason != "" {
			job.reason = reason
			job.resume = false
		}
		return
	}
	job.stopping = true
	job.reason = reason
	job.resume = resume
	go job.capture.Stop()
}

func (m *Manager) run() {
	defer close(m.done)
	ticker := time.NewTicker(m.config.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-m.stop:
			return
		case <-ticker.C:
			m.mu.Lock()
			if !m.closed && !m.readOnly {
				m.tickLocked()
			}
			m.mu.Unlock()
		}
	}
}

func (m *Manager) Close() error {
	m.closeOnce.Do(func() {
		m.mu.Lock()
		m.closed = true
		close(m.stop)
		m.mu.Unlock()
		<-m.done
		m.mu.Lock()
		jobs := make(map[string]*activeJob, len(m.jobs))
		for id, j := range m.jobs {
			if !j.stopping {
				j.reason = "plugin stopped"
				j.resume = true
				j.stopping = true
			}
			jobs[id] = j
		}
		m.mu.Unlock()
		var wg sync.WaitGroup
		for _, j := range jobs {
			wg.Add(1)
			go func(j *activeJob) { defer wg.Done(); j.capture.Stop() }(j)
		}
		wg.Wait()
		m.mu.Lock()
		defer m.mu.Unlock()
		for id, j := range jobs {
			result := <-j.capture.Done()
			if err := m.finishLocked(id, j, result); err != nil {
				m.closeErr = err
			}
		}
		if !m.readOnly {
			s := m.state.clone()
			if now := m.config.Now(); now.After(parseTime(s.Cursor)) {
				s.Cursor = timestamp(now)
			}
			pruneSeen(&s)
			if err := m.commit(s); err != nil {
				m.closeErr = err
			}
		}
		m.notify()
	})
	return m.closeErr
}

func (m *Manager) usedLocked() int64 {
	var used int64
	for _, r := range m.state.Recordings {
		if info, _, err := managedInfo(r); err == nil {
			used += info.Size()
		} else if r.Status != "missing" && r.Status != "missed" {
			used += r.Bytes
		}
	}
	return used
}

func (m *Manager) tickLocked() {
	if m.closed || m.readOnly {
		return
	}
	now := m.config.Now()
	if len(m.jobs) == 0 {
		work := false
		for _, rule := range m.state.Schedules {
			if rule.Enabled {
				work = true
				break
			}
		}
		if !work {
			for _, row := range m.state.Recordings {
				if row.Resume {
					work = true
					break
				}
			}
		}
		if !work {
			m.lastNow = now
			return
		}
	}
	if err := m.compactLocked(); err != nil {
		return
	}
	gap := now.Round(0).Sub(m.lastNow.Round(0))
	threshold := 5 * time.Second
	if m.config.PollInterval*4 > threshold {
		threshold = m.config.PollInterval * 4
	}
	if gap > threshold || gap < -2*time.Second {
		for _, j := range m.jobs {
			m.requestStop(j, "wall clock or suspend interruption", true)
		}
	}
	m.lastNow = now
	for id, j := range m.jobs {
		select {
		case result := <-j.capture.Done():
			if err := m.finishLocked(id, j, result); err != nil {
				return
			}
		default:
		}
	}
	if m.usedLocked() >= m.state.Settings.StorageCapBytes {
		for _, j := range m.jobs {
			m.requestStop(j, "library storage cap reached", false)
		}
	}
	for id, j := range m.jobs {
		for _, r := range m.state.Recordings {
			if r.ID != id {
				continue
			}
			if !now.Before(parseTime(r.PlannedEnd)) {
				m.requestStop(j, "", false)
			}
			if _, _, err := managedInfo(r); err != nil {
				m.requestStop(j, "recording file became unavailable", false)
			}
			free, err := m.freeBytes(r.Folder)
			if err != nil {
				m.requestStop(j, "cannot inspect recording free space", false)
			} else if free <= m.state.Settings.FreeSpaceReserveBytes {
				m.requestStop(j, "free-space reserve reached", false)
			}
		}
	}
	// Persisted resume intent creates a separate, linked remainder segment.
	for _, r := range append([]entry{}, m.state.Recordings...) {
		if !r.Resume {
			continue
		}
		if _, ok := m.jobs[r.ID]; ok {
			continue
		}
		if r.ResumeAfter != "" && now.Before(parseTime(r.ResumeAfter)) && now.Before(parseTime(r.PlannedEnd)) {
			continue
		}
		if now.Before(parseTime(r.PlannedEnd)) && !now.Before(parseTime(r.PlannedStart)) {
			rule := Schedule{ID: r.ScheduleID, Label: r.Label, StationID: r.StationID, StationName: r.StationName, StreamURL: r.StreamURL}
			o := occurrence{Key: r.Occurrence, Start: parseTime(r.PlannedStart), End: parseTime(r.PlannedEnd)}
			if err := m.startLocked(rule, o, now, r.ID); err != nil {
				m.fail(err)
				return
			}
		} else if !now.Before(parseTime(r.PlannedEnd)) {
			s := m.state.clone()
			for i := range s.Recordings {
				if s.Recordings[i].ID == r.ID {
					s.Recordings[i].Resume = false
				}
			}
			if err := m.commit(s); err != nil {
				return
			}
		}
	}
	enabled := false
	for _, s := range m.state.Schedules {
		if s.Enabled {
			enabled = true
			break
		}
	}
	if !enabled && len(m.jobs) == 0 {
		return
	}
	if err := m.boundCatchupLocked(now); err != nil {
		m.fail(err)
		return
	}
	if err := m.scheduleLocked(now); err != nil {
		m.fail(err)
		return
	}
	// Checkpoint a bounded clock window without writing every poll.
	if now.After(parseTime(m.state.Cursor).Add(time.Minute)) {
		s := m.state.clone()
		s.Cursor = timestamp(now)
		pruneSeen(&s)
		if err := m.persist(m.path, s); err != nil {
			m.persistenceFailed(s, err)
			return
		}
		m.state = s
	}
	if len(m.jobs) > 0 {
		m.notify()
	}
}

func (m *Manager) scheduleLocked(now time.Time) error {
	for _, rule := range m.state.Schedules {
		if !rule.Enabled {
			continue
		}
		loc, _ := time.LoadLocation(rule.Timezone)
		from := parseTime(m.state.Cursor)
		created := parseTime(m.state.RuleFrom[rule.ID])
		if from.Before(created) {
			from = created
		}
		if from.After(now) {
			continue
		}
		localFrom, localNow := from.In(loc), now.In(loc)
		day := time.Date(localFrom.Year(), localFrom.Month(), localFrom.Day(), 12, 0, 0, 0, loc).AddDate(0, 0, -1)
		last := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 12, 0, 0, 0, loc)
		for scanned := 0; !day.After(last); scanned++ {
			if scanned > maxOccurrences {
				return boundsError("scheduler catch-up days", maxOccurrences)
			}
			if chosenDay(rule, day) {
				o := occurrenceOn(rule, day)
				if !o.Start.After(now) && !o.End.Before(created) && (!o.End.Before(from) || o.Start.After(from)) && !m.state.Seen[o.Key] {
					if err := m.startLocked(rule, o, now, ""); err != nil {
						return err
					}
				}
			}
			day = day.AddDate(0, 0, 1)
		}
	}
	return nil
}

func (m *Manager) startLocked(rule Schedule, o occurrence, now time.Time, parent string) error {
	if len(m.state.Recordings) >= maxRecordings {
		return boundsError("recording history", maxRecordings)
	}
	if !m.state.Seen[o.Key] && len(m.state.Seen) >= maxOccurrences {
		return boundsError("occurrence ledger", maxOccurrences)
	}
	r := entry{Recording: Recording{ID: newID(), ScheduleID: rule.ID, Label: rule.Label, StationID: rule.StationID, StationName: rule.StationName, PlannedStart: timestamp(o.Start), PlannedEnd: timestamp(o.End), Status: "recording", Folder: m.state.Settings.Folder, ParentID: parent}, StreamURL: rule.StreamURL, Occurrence: o.Key}
	reason := o.Reason
	if reason == "" && m.dependencyError != "" {
		reason = m.dependencyError
	}
	if reason == "" && !now.Before(o.End) {
		reason = "scheduled interval elapsed while plugin was unavailable"
	}
	if reason == "" && len(m.jobs) >= m.state.Settings.Concurrency {
		reason = "simultaneous recording limit reached"
	}
	if reason == "" && m.usedLocked() >= m.state.Settings.StorageCapBytes {
		reason = "library storage cap reached"
	}
	if reason == "" {
		if err := os.MkdirAll(r.Folder, 0700); err != nil {
			reason = "recording folder is unavailable or unwritable"
		} else if free, err := m.freeBytes(r.Folder); err != nil {
			reason = "cannot inspect recording free space"
		} else if free <= m.state.Settings.FreeSpaceReserveBytes {
			reason = "free-space reserve reached"
		}
	}
	if reason != "" {
		r.Status = "missed"
		r.Reason = reason
		r.EndedAt = timestamp(now)
	} else {
		r.Filename = r.ID + ".partial"
		r.StartedAt = timestamp(now)
		if now.Sub(o.Start) > 2*time.Second {
			r.Reason = "started after scheduled beginning"
		}
	}
	s := m.state.clone()
	if parent != "" {
		for i := range s.Recordings {
			if s.Recordings[i].ID == parent {
				r.Failures = s.Recordings[i].Failures
				s.Recordings[i].Resume = false
				s.Recordings[i].ResumeAfter = ""
			}
		}
	}
	s.Recordings = append(s.Recordings, r)
	s.Seen[o.Key] = true
	if err := m.commit(s); err != nil {
		return err
	}
	if reason != "" {
		return nil
	}
	// Persist the identity before creating media or launching any process.
	job, err := m.startCapture(context.Background(), CaptureOptions{FFmpeg: m.config.FFmpeg, FFprobe: m.config.FFprobe, URL: r.StreamURL, Path: filepath.Join(r.Folder, r.Filename), End: o.End, StopGrace: m.config.StopGrace})
	if err != nil {
		s = m.state.clone()
		i := len(s.Recordings) - 1
		s.Recordings[i].Status = "error"
		s.Recordings[i].Reason = "cannot start recording encoder"
		s.Recordings[i].EndedAt = timestamp(now)
		return m.commit(s)
	}
	m.jobs[r.ID] = &activeJob{capture: job}
	m.notify()
	return nil
}

func (m *Manager) finishLocked(id string, job *activeJob, result CaptureResult) error {
	if m.readOnly {
		delete(m.jobs, id)
		return errors.New(m.err)
	}
	s := m.state.clone()
	found := -1
	for i := range s.Recordings {
		if s.Recordings[i].ID == id {
			found = i
			break
		}
	}
	if found < 0 {
		return errors.New("active recording missing from index")
	}
	r := &s.Recordings[found]
	r.EndedAt = timestamp(m.config.Now())
	r.Bytes = result.Bytes
	r.DurationSeconds = result.DurationSeconds
	r.Resume = job.resume
	if job.reason != "" {
		r.Reason = job.reason
	}
	if result.Err != nil && r.Reason == "" {
		r.Reason = "stream or encoder interrupted"
	}
	if job.reason == "" && m.config.Now().Before(parseTime(r.PlannedEnd).Add(-2*time.Second)) {
		// Unexpected EOF and stream/encoder failures retry at most twice, while
		// explicit user/storage/lifecycle stops keep their own resume policy.
		r.Failures++
		if r.Failures < 3 {
			r.Resume = true
			r.ResumeAfter = timestamp(m.config.Now().Add(time.Duration(r.Failures) * time.Second))
		} else {
			r.Resume = false
			r.Reason = "stream interrupted; recording retry limit reached"
		}
	}
	if result.Bytes > 0 && result.DurationSeconds > 0 {
		r.Status = "complete"
		if r.Reason != "" || m.config.Now().Before(parseTime(r.PlannedEnd).Add(-2*time.Second)) {
			r.Status = "partial"
			if r.Reason == "" {
				r.Reason = "recording ended before scheduled end"
			}
		}
		if info, path, err := managedInfo(*r); err == nil && info.Size() > 0 {
			if filepath.Ext(path) == ".partial" {
				if err = finalizeFile(path, filepath.Join(r.Folder, r.ID+".opus")); err != nil {
					r.Status = "partial"
					r.Reason = "could not finalize recording filename"
				} else {
					r.Filename = r.ID + ".opus"
				}
			} else {
				r.Filename = r.ID + ".opus"
			}
		} else {
			r.Status = "missing"
			r.Reason = "recorded audio file is missing or unsafe"
		}
	} else {
		r.Status = "error"
		if r.Reason == "" {
			r.Reason = "recording produced no recoverable audio"
		}
	}
	// Retain the active runtime until the durable transition succeeds. Its Done
	// result is cached by replacing the completed capture below on write failure.
	if err := m.commit(s); err != nil {
		job.capture = &finishedCapture{result: result, done: resultChannel(result)}
		return err
	}
	delete(m.jobs, id)
	return nil
}

type finishedCapture struct {
	result CaptureResult
	done   chan CaptureResult
}

func resultChannel(r CaptureResult) chan CaptureResult {
	c := make(chan CaptureResult, 1)
	c <- r
	close(c)
	return c
}
func (c *finishedCapture) Done() <-chan CaptureResult { return c.done }
func (c *finishedCapture) Stop()                      {}

func (m *Manager) recoverLocked() {
	s := m.state.clone()
	changed := false
	for i := 0; i < len(s.Recordings); i++ {
		r := &s.Recordings[i]
		if r.Deleting {
			if err := removeManaged(*r); err != nil {
				m.fail(err)
				continue
			}
			s.Recordings = append(s.Recordings[:i], s.Recordings[i+1:]...)
			i--
			changed = true
			continue
		}
		if r.Filename == "" {
			continue
		}
		info, path, err := managedInfo(*r)
		if err != nil {
			wasRecording := r.Status == "recording"
			if r.Status != "missing" {
				r.Status = "missing"
				r.Reason = "recorded audio file is missing or unsafe"
				r.Resume = wasRecording || r.Resume
				changed = true
			}
			continue
		}
		if r.Status == "recording" {
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			result, probeErr := ProbeRecording(ctx, m.config.FFprobe, path)
			cancel()
			r.Status = "partial"
			r.Reason = "plugin interrupted; recovered retained audio"
			r.EndedAt = timestamp(m.config.Now())
			r.Bytes = info.Size()
			r.DurationSeconds = result.DurationSeconds
			r.Resume = true
			if probeErr != nil || result.DurationSeconds <= 0 {
				r.Status = "error"
				r.Reason = "interrupted output could not be validated"
			}
			if filepath.Ext(path) == ".opus" {
				r.Filename = r.ID + ".opus"
			}
			changed = true
		}
	}
	if changed {
		if err := m.commit(s); err != nil {
			m.readOnly = true
			m.fail(err)
		}
	}
}

func finalizeFile(partial, final string) error {
	// Linking is atomic and fails if the final name already exists. Never replace
	// an existing file, including one planted after the capture began.
	f, err := os.Open(partial)
	if err != nil {
		return err
	}
	err = f.Sync()
	f.Close()
	if err != nil {
		return err
	}
	if err := os.Link(partial, final); err != nil {
		return err
	}
	if err := os.Remove(partial); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(final))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (m *Manager) compactLocked() error {
	cutoff := parseTime(m.state.Cursor).UTC().AddDate(0, 0, -3).Format("2006-01-02")
	eligible := false
	for key := range m.state.Seen {
		if _, date, ok := strings.Cut(key, ":"); ok && date < cutoff {
			eligible = true
			break
		}
	}
	if !eligible {
		return nil
	}
	s := m.state.clone()
	if !pruneSeen(&s) {
		return nil
	}
	return m.checkpointLocked(s)
}

func (m *Manager) checkpointLocked(s diskState) error {
	if err := m.persist(m.path, s); err != nil {
		return m.persistenceFailed(s, err)
	}
	m.state = s
	return nil
}

func (m *Manager) boundCatchupLocked(now time.Time) error {
	from := parseTime(m.state.Cursor)
	boundary := now.Add(-7 * 24 * time.Hour)
	if !boundary.After(from) {
		return nil
	}
	// A one-time rule has exactly one interval; preserve its actual missed
	// occurrence even when the general weekly catch-up window is bounded.
	for _, rule := range m.state.Schedules {
		if !rule.Enabled || rule.Kind != "once" {
			continue
		}
		day, _ := time.Parse("2006-01-02", rule.Date)
		o := occurrenceOn(rule, day)
		created := parseTime(m.state.RuleFrom[rule.ID])
		if o.Start.Before(boundary) && !o.End.Before(created) && (!o.End.Before(from) || o.Start.After(from)) && !m.state.Seen[o.Key] {
			if err := m.startLocked(rule, o, now, ""); err != nil {
				return err
			}
		}
	}
	s := m.state.clone()
	summaries := 0
	for _, rule := range s.Schedules {
		if !rule.Enabled || rule.Kind == "once" {
			continue
		}
		start := from
		if created := parseTime(s.RuleFrom[rule.ID]); created.After(start) {
			start = created
		}
		if !start.Before(boundary) {
			continue
		}
		if len(s.Recordings) >= maxRecordings {
			return boundsError("recording history", maxRecordings)
		}
		s.Recordings = append(s.Recordings, entry{Recording: Recording{ID: newID(), ScheduleID: rule.ID, Label: rule.Label, StationID: rule.StationID, StationName: rule.StationName, PlannedStart: timestamp(start), PlannedEnd: timestamp(boundary), EndedAt: timestamp(now), Status: "missed", Reason: "plugin unavailable for more than seven days; older missed intervals grouped in this row"}, StreamURL: rule.StreamURL, Occurrence: rule.ID + ":summary"})
		summaries++
	}
	s.Cursor = timestamp(boundary)
	pruneSeen(&s)
	if summaries > 0 {
		return m.commit(s)
	}
	return m.checkpointLocked(s)
}

func checkDependencies(config Config) string {
	if _, err := exec.LookPath(config.FFmpeg); err != nil {
		return "recording encoder unavailable: install FFmpeg with libopus"
	}
	if _, err := exec.LookPath(config.FFprobe); err != nil {
		return "recording probe unavailable: install FFprobe"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, config.FFmpeg, "-hide_banner", "-encoders")
	var output limitedBuffer
	cmd.Stdout = &output
	if err := cmd.Run(); err != nil || output.overflow || !bytes.Contains(output.Bytes(), []byte("libopus")) {
		return "recording encoder unavailable: FFmpeg requires libopus"
	}
	return ""
}
