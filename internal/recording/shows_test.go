package recording

import (
	"os"
	"testing"
	"time"
)

func TestShowIdentityKeepsOccurrencesSeparateAndSurvivesDeletion(t *testing.T) {
	part := func(id, parent, occurrence, start string) entry {
		return entry{Recording: Recording{ID: id, ParentID: parent, ScheduleID: "weekly", StationID: "station", Label: "Same title", PlannedStart: start, PlannedEnd: start + "-end"}, Occurrence: occurrence}
	}
	a := part("original", "", "weekly:2026-01-05", "one")
	b := part("retry", a.ID, a.Occurrence, "one")
	c := part("remainder", b.ID, a.Occurrence, "one")
	next := part("next-week", "", "weekly:2026-01-12", "two")
	summary := part("summary", "", a.Occurrence, "summary-window")
	ids := recordingShowIDs([]entry{c, next, a, summary, b})
	if ids[a.ID] != ids[b.ID] || ids[a.ID] != ids[c.ID] || ids[a.ID] == ids[next.ID] || ids[a.ID] == ids[summary.ID] {
		t.Fatal("wrong occurrence grouping", ids)
	}
	remaining := recordingShowIDs([]entry{c})
	if remaining[c.ID] != ids[a.ID] {
		t.Fatal("deleting predecessors changed occurrence identity")
	}
	// Old indexes can still use links, including siblings with a deleted parent.
	a.Occurrence, b.Occurrence, c.Occurrence = "", "", ""
	c.ParentID = a.ID
	legacy := recordingShowIDs([]entry{c, b})
	if legacy[b.ID] != legacy[c.ID] {
		t.Fatal("legacy siblings split after parent deletion")
	}
	other := part("unrelated", "", "", "one")
	legacy = recordingShowIDs([]entry{a, b, c, other})
	if legacy[a.ID] != legacy[c.ID] || legacy[a.ID] == legacy[other.ID] {
		t.Fatal("legacy links were ignored or unrelated recordings merged")
	}
}

func TestPlaybackBookmarkRetainsPartAndCompletionAfterReopen(t *testing.T) {
	m, now, _ := engineFixture(t)
	if err := m.StartNow(m.Snapshot().Revision, rule("unused"), time.Minute); err != nil {
		t.Fatal(err)
	}
	id := m.Snapshot().Recordings[0].ID
	if err := m.StopRecording(m.Snapshot().Revision, id); err != nil {
		t.Fatal(err)
	}
	waitFinished(t, m)
	// A second retained part shares the frozen occurrence and audio fixture.
	m.mu.Lock()
	s := m.state.clone()
	b := s.Recordings[0]
	b.ID, b.ParentID, b.Filename = "second", id, ""
	s.Recordings = append(s.Recordings, b)
	err := m.commit(s)
	m.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	revision := m.Snapshot().Revision
	if err := m.SetPlaybackProgress(id, 0, true); err != nil {
		t.Fatal(err)
	}
	if err := m.SetPlaybackPosition("second", 2); err != nil {
		t.Fatal(err)
	}
	// Selecting the original again at zero must become the latest bookmark,
	// even with an unchanged/retreating clock and unchanged position.
	*now = now.Add(-time.Hour)
	if err := m.SetPlaybackPosition(id, 0); err != nil {
		t.Fatal(err)
	}
	if m.Snapshot().Revision != revision {
		t.Fatal("playback checkpoint invalidated editing drafts")
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	state, err := loadState(m.path)
	if err != nil {
		t.Fatal(err)
	}
	a, b := state.Recordings[0], state.Recordings[1]
	if a.PlaybackCompleted || !parseTime(a.LastPlayedAt).After(parseTime(b.LastPlayedAt)) || b.ResumePosition != 2 {
		t.Fatalf("lost bookmark or invalidated drafts: %+v %+v", a, b)
	}
	if a.ShowID != "" {
		t.Fatal("derived show identity leaked into the index")
	}
	if err := m.SetPlaybackProgress(id, 0, true); err == nil {
		t.Fatal("closed manager accepted a bookmark")
	}
	state.Recordings[0].LastPlayedAt = "invalid"
	if validateState(state) == nil {
		t.Fatal("invalid bookmark timestamp accepted")
	}
	// Snapshot-derived identities do not require an index rewrite.
	before, _ := os.ReadFile(m.path)
	m.Snapshot()
	after, _ := os.ReadFile(m.path)
	if string(before) != string(after) {
		t.Fatal("snapshot wrote the index")
	}
}
