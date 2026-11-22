package recording

import (
	"encoding/json"
	"testing"
	"time"
)

func TestPaddingPreviewAcrossMidnightAndDST(t *testing.T) {
	s := rule("padding")
	s.Kind, s.Date, s.Timezone = "once", "2026-11-01", "America/New_York"
	s.StartTime, s.EndTime = "01:30", "02:30"
	s.PreRollSeconds, s.PostRollSeconds = 30, 60
	p, err := PreviewSchedule(s, time.Date(2026, 10, 31, 0, 0, 0, 0, time.UTC))
	if err != nil || p.NextStart != "2026-11-01T01:30:00-04:00" || p.NextCaptureStart != "2026-11-01T01:29:30-04:00" || p.NextCaptureEnd != "2026-11-01T02:31:00-05:00" {
		t.Fatalf("padded DST preview: %+v %v", p, err)
	}
	s.Date, s.StartTime, s.EndTime = "2026-11-02", "00:00", "00:01"
	p, err = PreviewSchedule(s, time.Date(2026, 11, 2, 4, 59, 0, 0, time.UTC))
	if err != nil || p.NextCaptureStart != "2026-11-01T23:59:30-05:00" {
		t.Fatalf("padding across midnight: %+v %v", p, err)
	}
	// The capture remains upcoming during its post-roll even after the show ends.
	p, err = PreviewSchedule(s, time.Date(2026, 11, 2, 5, 1, 30, 0, time.UTC))
	if err != nil || p.NextCaptureEnd != "2026-11-02T00:02:00-05:00" {
		t.Fatalf("post-roll preview: %+v %v", p, err)
	}
	for _, padding := range []int{-1, 601} {
		s.PreRollSeconds = padding
		if _, err := PreviewSchedule(s, time.Now()); err == nil {
			t.Fatal("invalid padding accepted")
		}
	}
}

func TestOldSchedulesKeepUnpaddedTiming(t *testing.T) {
	var s Schedule
	if err := json.Unmarshal([]byte(`{"id":"old","stationId":"station","stationName":"Station","streamUrl":"https://example.test/live","weekdays":[1],"startTime":"10:00","endTime":"11:00","timezone":"UTC","enabled":true}`), &s); err != nil {
		t.Fatal(err)
	}
	p, err := PreviewSchedule(s, time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC))
	if err != nil || p.NextStart != p.NextCaptureStart || p.NextEnd != p.NextCaptureEnd || s.PreRollSeconds != 0 || s.PostRollSeconds != 0 {
		t.Fatalf("old timing changed: %+v %v", p, err)
	}
}

func TestWeeklyDSTAndOvernight(t *testing.T) {
	s := rule("dst")
	s.Timezone = "America/New_York"
	s.Weekdays = []int{0}
	s.StartTime = "01:30"
	s.EndTime = "02:30"
	day := time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)
	o := occurrenceOn(s, day)
	if got := o.Start.Format(time.RFC3339); got != "2026-11-01T05:30:00Z" {
		t.Fatalf("fold start %s", got)
	}
	if o.End.Sub(o.Start) != 2*time.Hour {
		t.Fatalf("fold duration %s", o.End.Sub(o.Start))
	}
	s.StartTime = "02:30"
	s.EndTime = "03:30"
	o = occurrenceOn(s, time.Date(2026, 3, 8, 12, 0, 0, 0, time.UTC))
	if o.Reason == "" {
		t.Fatal("nonexistent start accepted")
	}
	s.StartTime = "01:30"
	s.EndTime = "02:30"
	o = occurrenceOn(s, time.Date(2026, 3, 8, 12, 0, 0, 0, time.UTC))
	if o.Reason == "" {
		t.Fatal("nonexistent end accepted")
	}
	s.Timezone = "UTC"
	s.StartTime = "23:45"
	s.EndTime = "00:15"
	o = occurrenceOn(s, day)
	if o.End.Sub(o.Start) != 30*time.Minute || o.End.Day() != 2 {
		t.Fatalf("overnight %+v", o)
	}
}

func TestPreviewUsesWeeklyZoneAndOffset(t *testing.T) {
	s := rule("weekly")
	s.Timezone = "America/New_York"
	p := preview(s, time.Date(2026, 1, 5, 14, 0, 0, 0, time.UTC))
	if p.NextStart != "2026-01-05T10:00:00-05:00" {
		t.Fatal(p.NextStart)
	}
	s.Enabled = false
	if preview(s, time.Now()).NextStart != "" {
		t.Fatal("disabled preview")
	}
}

func TestPublicSchedulePreviewValidatesAndResolvesWithoutID(t *testing.T) {
	s := rule("")
	p, err := PreviewSchedule(s, time.Date(2026, 1, 5, 9, 0, 0, 0, time.UTC))
	if err != nil || p.NextStart != "2026-01-05T10:00:00Z" || s.ID != "" {
		t.Fatal("read-only preview", p, err)
	}
	s.Weekdays = nil
	if _, err := PreviewSchedule(s, time.Now()); err == nil {
		t.Fatal("preview accepted invalid weekday selection")
	}
}

func TestOncePreviewDSTAndOvernight(t *testing.T) {
	s := rule("once")
	s.Kind, s.Date, s.Timezone, s.StartTime, s.EndTime, s.Weekdays = "once", "2026-03-08", "America/New_York", "02:30", "03:30", nil
	got, err := PreviewSchedule(s, time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || got.NextStart != "" {
		t.Fatalf("gap: %+v %v", got, err)
	}
	s.Date, s.StartTime, s.EndTime = "2026-11-01", "01:30", "02:30"
	got, err = PreviewSchedule(s, time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || got.NextStart != "2026-11-01T01:30:00-04:00" || got.NextEnd != "2026-11-01T02:30:00-05:00" {
		t.Fatalf("fold: %+v %v", got, err)
	}
	s.Date, s.StartTime, s.EndTime = "2026-11-02", "23:30", "00:30"
	got, err = PreviewSchedule(s, time.Date(2026, 11, 3, 4, 45, 0, 0, time.UTC))
	if err != nil || got.NextEnd != "2026-11-03T00:30:00-05:00" {
		t.Fatalf("overnight: %+v %v", got, err)
	}
	s.Date = "2026-02-30"
	if _, err = PreviewSchedule(s, time.Now()); err == nil {
		t.Fatal("accepted invalid date")
	}
}

func TestOnceDateWithMidnightDSTGap(t *testing.T) {
	s := rule("santiago")
	s.Kind, s.Date, s.Timezone, s.StartTime, s.EndTime, s.Weekdays = "once", "2026-09-06", "America/Santiago", "01:30", "02:30", nil
	got, err := PreviewSchedule(s, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || got.NextStart != "2026-09-06T01:30:00-03:00" || got.NextEnd != "2026-09-06T02:30:00-03:00" {
		t.Fatalf("midnight transition date: %+v %v", got, err)
	}
	s.StartTime = "00:30"
	got, err = PreviewSchedule(s, time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC))
	if err != nil || got.NextStart != "" {
		t.Fatalf("nonexistent start: %+v %v", got, err)
	}
}
