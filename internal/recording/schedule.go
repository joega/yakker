package recording

import (
	"errors"
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

const maxSchedules = 100
const maxRecordings = 4096
const maxOccurrences = 8192
const maxIndexBytes = 8 << 20
const maxPaddingSeconds = 600

var identifier = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$`)

func textOK(s string, max int) bool {
	if len(s) > max {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validateSettings(s Settings) error {
	if !filepath.IsAbs(s.Folder) || filepath.Clean(s.Folder) != s.Folder || !textOK(s.Folder, 4096) {
		return errors.New("recording folder must be a clean absolute path")
	}
	if s.StorageCapBytes < 1 || s.StorageCapBytes > 1<<60 || s.FreeSpaceReserveBytes < 0 || s.FreeSpaceReserveBytes > 1<<60 {
		return errors.New("invalid recording storage limits")
	}
	if s.Concurrency < 1 || s.Concurrency > 3 {
		return errors.New("recording concurrency must be between 1 and 3")
	}
	return nil
}

func clockMinutes(s string) (int, error) {
	t, err := time.Parse("15:04", s)
	if err != nil || t.Format("15:04") != s {
		return 0, errors.New("times must use HH:mm")
	}
	return t.Hour()*60 + t.Minute(), nil
}

func validateSchedule(s Schedule) error {
	if s.PreRollSeconds < 0 || s.PreRollSeconds > maxPaddingSeconds || s.PostRollSeconds < 0 || s.PostRollSeconds > maxPaddingSeconds {
		return errors.New("schedule padding must be between 0 and 600 seconds on each side")
	}
	if !identifier.MatchString(s.ID) || !identifier.MatchString(s.StationID) {
		return errors.New("invalid schedule or station identifier")
	}
	if !textOK(s.Label, 256) || !textOK(s.StationName, 256) || strings.TrimSpace(s.StationName) == "" {
		return errors.New("invalid recording label or station name")
	}
	if !validStreamURL(s.StreamURL) {
		return errors.New("recording stream must use an HTTP or HTTPS URL")
	}
	switch s.Kind {
	case "", "weekly":
		if len(s.Weekdays) < 1 || len(s.Weekdays) > 7 {
			return errors.New("choose at least one weekday")
		}
		seen := map[int]bool{}
		for _, d := range s.Weekdays {
			if d < 0 || d > 6 || seen[d] {
				return errors.New("invalid or repeated weekday")
			}
			seen[d] = true
		}
	case "once":
		date, err := time.Parse("2006-01-02", s.Date)
		if err != nil || date.Format("2006-01-02") != s.Date {
			return errors.New("date must use YYYY-MM-DD")
		}
	default:
		return errors.New("invalid schedule kind")
	}
	a, err := clockMinutes(s.StartTime)
	if err != nil {
		return err
	}
	b, err := clockMinutes(s.EndTime)
	if err != nil {
		return err
	}
	d := (b - a + 1440) % 1440
	if d == 0 || d > 720 {
		return errors.New("recordings must last between 1 minute and 12 hours")
	}
	if s.Timezone == "" || s.Timezone == "Local" || len(s.Timezone) > 128 {
		return errors.New("choose an explicit IANA timezone")
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil {
		return errors.New("unknown IANA timezone")
	}
	return nil
}

func validStreamURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && textOK(raw, 4096) && (u.Scheme == "https" || u.Scheme == "http") && u.Host != ""
}

// Resolve wall times by checking each actual zone offset around this date. This
// avoids time.Date's unspecified choice in folds and normalization of gaps.
func wallInstants(date time.Time, minute int, loc *time.Location) []time.Time {
	y, m, d := date.Date()
	nominal := time.Date(y, m, d, minute/60, minute%60, 0, 0, time.UTC)
	offsets := map[int]bool{}
	for h := -36; h <= 36; h += 3 {
		_, offset := nominal.Add(time.Duration(h) * time.Hour).In(loc).Zone()
		offsets[offset] = true
	}
	var matches []time.Time
	for offset := range offsets {
		candidate := nominal.Add(-time.Duration(offset) * time.Second)
		local := candidate.In(loc)
		if local.Year() == y && local.Month() == m && local.Day() == d && local.Hour() == minute/60 && local.Minute() == minute%60 {
			matches = append(matches, candidate)
		}
	}
	sort.Slice(matches, func(i, j int) bool { return matches[i].Before(matches[j]) })
	return matches
}

type occurrence struct {
	Key                      string
	Start, End               time.Time
	Reason                   string
	CaptureStart, CaptureEnd time.Time
}

func (o occurrence) captureStart() time.Time {
	if !o.CaptureStart.IsZero() {
		return o.CaptureStart
	}
	return o.Start
}
func (o occurrence) captureEnd() time.Time {
	if !o.CaptureEnd.IsZero() {
		return o.CaptureEnd
	}
	return o.End
}

func occurrenceOn(s Schedule, date time.Time) occurrence {
	loc, _ := time.LoadLocation(s.Timezone)
	a, _ := clockMinutes(s.StartTime)
	b, _ := clockMinutes(s.EndTime)
	y, m, d := date.Date()
	// Keep the requested civil date independent of timezone normalization.
	day := time.Date(y, m, d, 12, 0, 0, 0, time.UTC)
	o := occurrence{Key: s.ID + ":" + day.Format("2006-01-02")}
	starts := wallInstants(day, a, loc)
	if len(starts) == 0 {
		// Report a gap once the local clock has crossed it, rather than using
		// time.Date's normalization (which can move 02:30 back to 01:30).
		for minute := a + 1; minute < 1440; minute++ {
			if matches := wallInstants(day, minute, loc); len(matches) > 0 {
				o.Start = matches[0]
				break
			}
		}
		if o.Start.IsZero() {
			next := day.AddDate(0, 0, 1)
			for minute := 0; minute < 1440; minute++ {
				if matches := wallInstants(next, minute, loc); len(matches) > 0 {
					o.Start = matches[0]
					break
				}
			}
			if o.Start.IsZero() {
				o.Start = next.AddDate(0, 0, 1)
			}
		}
		o.End = o.Start
		o.Reason = "start time does not exist because of a timezone transition"
		return o
	}
	o.Start = starts[0]
	endDay := day
	if b <= a {
		endDay = day.AddDate(0, 0, 1)
	}
	for _, end := range wallInstants(endDay, b, loc) {
		if end.After(o.Start) {
			o.End = end
			break
		}
	}
	if o.End.IsZero() {
		o.End = o.Start
		o.Reason = "end time does not exist or is not after start"
	}
	if o.Reason == "" {
		o.CaptureStart = o.Start.Add(-time.Duration(s.PreRollSeconds) * time.Second)
		o.CaptureEnd = o.End.Add(time.Duration(s.PostRollSeconds) * time.Second)
	}
	return o
}

func chosenDay(s Schedule, day time.Time) bool {
	if s.Kind == "once" {
		return day.Format("2006-01-02") == s.Date
	}
	for _, d := range s.Weekdays {
		if d == int(day.Weekday()) {
			return true
		}
	}
	return false
}

func preview(s Schedule, now time.Time) Schedule {
	s.NextStart = ""
	s.NextEnd = ""
	s.NextCaptureStart, s.NextCaptureEnd = "", ""
	if !s.Enabled {
		return s
	}
	loc, err := time.LoadLocation(s.Timezone)
	if err != nil {
		return s
	}
	if s.Kind == "once" {
		day, err := time.Parse("2006-01-02", s.Date)
		if err == nil {
			o := occurrenceOn(s, day)
			if o.Reason == "" && o.captureEnd().After(now) {
				s.NextStart = o.Start.In(loc).Format(time.RFC3339)
				s.NextEnd = o.End.In(loc).Format(time.RFC3339)
				s.NextCaptureStart = o.captureStart().In(loc).Format(time.RFC3339)
				s.NextCaptureEnd = o.captureEnd().In(loc).Format(time.RFC3339)
			}
		}
		return s
	}
	date := now.In(loc).AddDate(0, 0, -1)
	for i := 0; i < 16; i++ {
		day := date.AddDate(0, 0, i)
		if !chosenDay(s, day) {
			continue
		}
		o := occurrenceOn(s, day)
		if o.Reason == "" && o.captureEnd().After(now) {
			s.NextStart = o.Start.In(loc).Format(time.RFC3339)
			s.NextEnd = o.End.In(loc).Format(time.RFC3339)
			s.NextCaptureStart = o.captureStart().In(loc).Format(time.RFC3339)
			s.NextCaptureEnd = o.captureEnd().In(loc).Format(time.RFC3339)
			break
		}
	}
	return s
}

// PreviewSchedule resolves the next occurrence without writing scheduler state.
func PreviewSchedule(s Schedule, now time.Time) (Schedule, error) {
	if s.ID == "" {
		s.ID = "preview"
	}
	if s.Timezone == "" {
		s.Timezone = machineTimezone()
	}
	if err := validateSchedule(s); err != nil {
		return Schedule{}, err
	}
	return preview(s, now), nil
}

func parseTime(s string) time.Time { t, _ := time.Parse(time.RFC3339Nano, s); return t }
func timestamp(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}
func boundsError(kind string, n int) error {
	return fmt.Errorf("%s limit reached (%d); remove retained entries before adding more", kind, n)
}
