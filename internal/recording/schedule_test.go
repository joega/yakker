package recording

import (
	"testing"
	"time"
)

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
