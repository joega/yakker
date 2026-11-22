package recording

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type entry struct {
	Recording
	StreamURL   string `json:"streamUrl,omitempty"`
	Occurrence  string `json:"occurrence"`
	Resume      bool   `json:"resume,omitempty"`
	Deleting    bool   `json:"deleting,omitempty"`
	Failures    int    `json:"failures,omitempty"`
	ResumeAfter string `json:"resumeAfter,omitempty"`
}

type diskState struct {
	Version    int               `json:"version"`
	Revision   int64             `json:"revision"`
	Settings   Settings          `json:"settings"`
	Schedules  []Schedule        `json:"schedules"`
	Recordings []entry           `json:"recordings"`
	Seen       map[string]bool   `json:"seen"`
	RuleFrom   map[string]string `json:"ruleFrom"`
	Cursor     string            `json:"cursor"`
}

type committedWriteError struct{ error }

var errIndexFull = errors.New("recording history index is full; delete retained history entries")

func (s diskState) clone() diskState {
	n := s
	n.Schedules = append([]Schedule{}, s.Schedules...)
	for i := range n.Schedules {
		n.Schedules[i].Weekdays = append([]int{}, n.Schedules[i].Weekdays...)
	}
	n.Recordings = append([]entry{}, s.Recordings...)
	n.Seen = make(map[string]bool, len(s.Seen))
	for k, v := range s.Seen {
		n.Seen[k] = v
	}
	n.RuleFrom = make(map[string]string, len(s.RuleFrom))
	for k, v := range s.RuleFrom {
		n.RuleFrom[k] = v
	}
	return n
}

func validateState(s diskState) error {
	if s.Version != 1 || s.Revision < 1 {
		return errors.New("unsupported recording index version or revision")
	}
	if err := validateSettings(s.Settings); err != nil {
		return err
	}
	if len(s.Schedules) > maxSchedules || len(s.Recordings) > maxRecordings || len(s.Seen) > maxOccurrences || len(s.RuleFrom) > maxSchedules {
		return errors.New("recording index exceeds collection limits")
	}
	if s.Seen == nil || s.RuleFrom == nil || parseTime(s.Cursor).IsZero() {
		return errors.New("recording index is missing scheduler state")
	}
	ids := map[string]bool{}
	for _, r := range s.Schedules {
		if err := validateSchedule(r); err != nil {
			return err
		}
		if ids[r.ID] {
			return errors.New("duplicate schedule identifier")
		}
		ids[r.ID] = true
		if parseTime(s.RuleFrom[r.ID]).IsZero() {
			return errors.New("missing schedule creation time")
		}
	}
	ids = map[string]bool{}
	for _, r := range s.Recordings {
		if r.Failures < 0 || r.Failures > 3 || (r.ResumeAfter != "" && parseTime(r.ResumeAfter).IsZero()) {
			return errors.New("invalid recording retry state")
		}
		if !identifier.MatchString(r.ID) || ids[r.ID] || !identifier.MatchString(r.ScheduleID) || !identifier.MatchString(r.StationID) || !textOK(r.Label, 256) || !textOK(r.StationName, 256) || !textOK(r.Reason, 1024) || r.Bytes < 0 || r.DurationSeconds < 0 || math.IsNaN(r.DurationSeconds) || math.IsInf(r.DurationSeconds, 0) || math.IsNaN(r.ResumePosition) || math.IsInf(r.ResumePosition, 0) || r.ResumePosition < 0 || r.ResumePosition > r.DurationSeconds {
			return errors.New("invalid recording index entry")
		}
		ids[r.ID] = true
		if !textOK(r.Folder, 4096) || (r.ParentID != "" && !identifier.MatchString(r.ParentID)) {
			return errors.New("invalid retained recording metadata")
		}
		if r.StreamURL != "" && !validStreamURL(r.StreamURL) {
			return errors.New("unsafe retained stream URL")
		}
		if (r.Resume || r.Status == "recording") && !validStreamURL(r.StreamURL) {
			return errors.New("missing retained stream URL")
		}
		if r.Filename != "" {
			if !filepath.IsAbs(r.Folder) || filepath.Clean(r.Folder) != r.Folder || !managedName(r.ID, r.Filename) {
				return errors.New("unsafe recording file path")
			}
		}
		switch r.Status {
		case "recording", "complete", "partial", "missed", "error", "missing":
		default:
			return errors.New("invalid recording status")
		}
		if parseTime(r.PlannedStart).IsZero() || parseTime(r.PlannedEnd).IsZero() || len(r.Occurrence) > 200 || !textOK(r.StreamURL, 4096) {
			return errors.New("invalid recording interval")
		}
		if (r.CaptureStart == "") != (r.CaptureEnd == "") || (r.CaptureStart != "" &&
			(parseTime(r.CaptureStart).IsZero() || parseTime(r.CaptureEnd).IsZero() ||
				r.captureStart().After(parseTime(r.PlannedStart)) || r.captureEnd().Before(parseTime(r.PlannedEnd)) ||
				parseTime(r.PlannedStart).Sub(r.captureStart()) > maxPaddingSeconds*time.Second ||
				r.captureEnd().Sub(parseTime(r.PlannedEnd)) > maxPaddingSeconds*time.Second)) {
			return errors.New("invalid recording capture window")
		}
	}
	for k, v := range s.Seen {
		id, date, ok := strings.Cut(k, ":")
		_, dateErr := time.Parse("2006-01-02", date)
		if len(k) > 200 || !v || !ok || !identifier.MatchString(id) || dateErr != nil {
			return errors.New("invalid occurrence ledger")
		}
	}
	return nil
}

func loadState(path string) (diskState, error) {
	f, err := os.Open(path)
	if err != nil {
		return diskState{}, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxIndexBytes+1))
	if err != nil {
		return diskState{}, err
	}
	if len(b) > maxIndexBytes {
		return diskState{}, errors.New("recording index exceeds 8 MiB")
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	var s diskState
	if err = d.Decode(&s); err != nil {
		return s, errors.New("recording index contains invalid JSON")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return s, errors.New("recording index contains trailing data")
	}
	return s, validateState(s)
}

func persistState(path string, s diskState) error {
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	if len(b) > maxIndexBytes {
		return errIndexFull
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".recordings-*.tmp")
	if err != nil {
		return errors.New("cannot create recording index temporary file")
	}
	name := f.Name()
	defer os.Remove(name)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return errors.New("cannot write recording index")
	}
	if err = os.Rename(name, path); err != nil {
		return errors.New("cannot replace recording index")
	}
	dir, err := os.Open(filepath.Dir(path))
	if err == nil {
		err = dir.Sync()
		dir.Close()
	}
	if err != nil {
		return committedWriteError{errors.New("recording index replaced but directory durability could not be confirmed; reopen before making changes")}
	}
	return nil
}

func managedName(id, name string) bool { return name == id+".opus" || name == id+".partial" }

// OpenRoot anchors operations to the retained folder. A final symlink is never
// accepted as audio, even when its target is also inside that folder.
func managedInfo(r entry) (os.FileInfo, string, error) {
	if r.Filename == "" || !managedName(r.ID, r.Filename) || !filepath.IsAbs(r.Folder) {
		return nil, "", errors.New("recording has no managed audio file")
	}
	root, err := os.OpenRoot(r.Folder)
	if err != nil {
		return nil, "", errors.New("recording folder is unavailable")
	}
	defer root.Close()
	info, err := root.Lstat(r.Filename)
	if errors.Is(err, os.ErrNotExist) && r.Filename == r.ID+".partial" {
		info, err = root.Lstat(r.ID + ".opus")
		if err == nil {
			r.Filename = r.ID + ".opus"
		}
	}
	if err != nil {
		return nil, "", err
	}
	if !info.Mode().IsRegular() {
		return nil, "", errors.New("recording file is not a regular file")
	}
	return info, filepath.Join(r.Folder, r.Filename), nil
}

func removeManaged(r entry) error {
	if r.Filename == "" {
		return nil
	}
	if !managedName(r.ID, r.Filename) {
		return errors.New("unsafe recording filename")
	}
	root, err := os.OpenRoot(r.Folder)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return errors.New("recording folder is unavailable")
	}
	defer root.Close()
	names := []string{r.Filename}
	other := r.ID + ".partial"
	if other == r.Filename {
		other = r.ID + ".opus"
	}
	current, currentErr := root.Lstat(r.Filename)
	alternate, alternateErr := root.Lstat(other)
	if currentErr == nil && alternateErr == nil && os.SameFile(current, alternate) {
		// An interrupted finalization may leave two links to our audio. Remove
		// the alternate first so the persisted primary remains recoverable.
		names = []string{other, r.Filename}
	}
	for _, name := range names {
		info, err := root.Lstat(name)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return errors.New("refusing to delete a nonregular recording file")
		}
		if err = root.Remove(name); err != nil {
			return errors.New("cannot delete recording file")
		}
	}
	dir, err := root.Open(".")
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

// A UTC high-water checkpoint excludes all older ended intervals. Keeping three
// additional date labels covers every IANA offset and overnight/fold interval.
func pruneSeen(s *diskState) bool {
	cutoff := parseTime(s.Cursor).UTC().AddDate(0, 0, -3).Format("2006-01-02")
	changed := false
	for key := range s.Seen {
		_, date, ok := strings.Cut(key, ":")
		if ok && date < cutoff {
			delete(s.Seen, key)
			changed = true
		}
	}
	return changed
}

func machineTimezone() string {
	valid := func(s string) bool {
		if s == "" || s == "Local" || strings.HasPrefix(s, "/") {
			return false
		}
		_, err := time.LoadLocation(s)
		return err == nil
	}
	if tz := strings.TrimPrefix(os.Getenv("TZ"), ":"); valid(tz) {
		return tz
	}
	if p, err := filepath.EvalSymlinks("/etc/localtime"); err == nil {
		if _, tail, ok := strings.Cut(p, "/zoneinfo/"); ok && valid(tail) {
			return tail
		}
	}
	if b, err := os.ReadFile("/etc/timezone"); err == nil {
		if tz := strings.TrimSpace(string(b)); valid(tz) {
			return tz
		}
	}
	return "UTC"
}

func indexError(err error) string { return fmt.Sprintf("recording index unavailable: %s", err) }
