package radio

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCustomPlayerLogDoesNotExposeURL(t *testing.T) {
	var output bytes.Buffer
	log := &playerLog{output: &output, private: true}
	_, _ = log.Write([]byte("failed https://user:secret@example.test/audio?token=secret"))
	if strings.Contains(output.String(), "secret") || strings.Contains(log.message(""), "secret") {
		t.Fatal("custom URL leaked")
	}
}

func TestCustomControllerPlaybackAndCorruptStartup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stations.json")
	id, err := NewCustomStationID()
	if err != nil {
		t.Fatal(err)
	}
	station := CustomStation{ID: id, Name: "Saved", StreamURL: "https://example.test/one"}
	bundled, err := LoadStations(stationFile)
	if err != nil {
		t.Fatal(err)
	}
	if err := SaveCustomStations(path, []CustomStation{station}, bundled); err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, Config{CustomStationFile: path}, false)
	serial := h.send("configure", "stationId", id)
	h.wait(func(s Status) bool { return s.Serial >= serial && s.Station["id"] == id })
	h.send("play")
	playing := h.wait(func(s Status) bool { return s.State == "playing" })
	station.StreamURL = "https://example.test/two"
	serial = h.send("upsertStation", "station", station)
	updated := h.wait(func(s Status) bool {
		return s.CustomMutationSerial == serial && s.CustomMutationOK && s.State == "playing"
	})
	if updated.PlayerPID == playing.PlayerPID || updated.Station["streamUrl"] != station.StreamURL {
		t.Fatal("active URL change did not reconnect")
	}
	serial = h.send("deleteStation", "stationId", id)
	removed := h.wait(func(s Status) bool { return s.CustomMutationSerial == serial && s.CustomMutationOK })
	if removed.Wanted || removed.Station["id"] == id || removed.PlayerPID != 0 {
		t.Fatalf("active delete: %#v", removed)
	}

	badPath := filepath.Join(t.TempDir(), "bad.json")
	if err := os.WriteFile(badPath, []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	bad := newHarness(t, Config{CustomStationFile: badPath}, false)
	serial = bad.send("upsertStation", "station", station)
	state := bad.wait(func(s Status) bool { return s.CustomMutationSerial == serial })
	if state.CustomMutationOK || state.CustomStationError == "" || len(state.Stations) != len(bundled) {
		t.Fatalf("bad startup: %#v", state)
	}
	data, _ := os.ReadFile(badPath)
	if string(data) != "broken" {
		t.Fatal("corrupt file overwritten")
	}
}

func TestCustomExternalChangeDoesNotOverwriteOrMutate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stations.json")
	id, _ := NewCustomStationID()
	original := CustomStation{ID: id, Name: "Original", StreamURL: "https://example.test/audio"}
	if err := SaveCustomStations(path, []CustomStation{original}, nil); err != nil {
		t.Fatal(err)
	}
	r := &controller{customPath: path, custom: []CustomStation{original}, state: Status{Station: Station{"id": id, "name": "Original"}, Serial: 1}}
	external := original
	external.Name = "External"
	if err := SaveCustomStations(path, []CustomStation{external}, nil); err != nil {
		t.Fatal(err)
	}
	r.updateCustomStation("deleteStation", map[string]json.RawMessage{"stationId": json.RawMessage(`"` + id + `"`)})
	got, err := LoadCustomStations(path, nil)
	if err != nil || len(got) != 1 || got[0].Name != "External" || r.state.CustomMutationOK || r.custom[0].Name != "Original" {
		t.Fatalf("external edit lost: %#v %#v %v", got, r.state, err)
	}
}

func TestCustomWriteFailureLeavesStateAndFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "stations.json")
	id, _ := NewCustomStationID()
	station := CustomStation{ID: id, Name: "Original", StreamURL: "https://example.test/audio"}
	if err := SaveCustomStations(path, []CustomStation{station}, nil); err != nil {
		t.Fatal(err)
	}
	r := &controller{customPath: path, custom: []CustomStation{station}, state: Status{Station: Station{"id": id, "name": "Original"}, Serial: 1}}
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0700)
	station.Name = "Changed"
	data, _ := json.Marshal(station)
	r.updateCustomStation("upsertStation", map[string]json.RawMessage{"station": data})
	got, err := LoadCustomStations(path, nil)
	if err != nil || got[0].Name != "Original" || r.state.CustomMutationOK || r.custom[0].Name != "Original" || r.state.Station["name"] != "Original" {
		t.Fatalf("failed write changed state: %#v %#v %v", got, r.state, err)
	}
}

func TestCustomStationControllerMutations(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stations.json")
	stock := []Station{{"id": "stock", "name": "Stock", "subtitle": "Stock", "streamUrl": "https://example.test/stock"}}
	r := &controller{bundled: stock, stations: stock, custom: []CustomStation{}, customPath: path, state: Status{Station: stock[0]}}
	command := func(action string, station any) {
		r.state.Serial++
		value, err := json.Marshal(station)
		if err != nil {
			t.Fatal(err)
		}
		data := map[string]json.RawMessage{}
		if action == "upsertStation" {
			data["station"] = value
		} else {
			data["stationId"] = value
		}
		r.updateCustomStation(action, data)
	}
	s := CustomStation{Name: "Test", StreamURL: "https://example.test/live"}
	command("upsertStation", s)
	if !r.state.CustomMutationOK || len(r.stations) != 2 {
		t.Fatalf("add: %#v", r.state)
	}
	id := r.custom[0].ID
	r.state.Station = r.stations[1]
	s.ID, s.Name = id, "Renamed"
	command("upsertStation", s)
	if !r.state.CustomMutationOK || r.state.Station["name"] != "Renamed" {
		t.Fatalf("edit: %#v", r.state)
	}
	before := r.state.Station
	s.StreamURL = "bad"
	command("upsertStation", s)
	if r.state.CustomMutationOK || r.state.Station["name"] != before["name"] {
		t.Fatal("invalid edit changed active station")
	}
	command("deleteStation", id)
	if !r.state.CustomMutationOK || r.state.Station["id"] != "stock" || r.state.Wanted {
		t.Fatalf("delete: %#v", r.state)
	}
	if got, err := LoadCustomStations(path, stock); err != nil || len(got) != 0 {
		t.Fatalf("persisted deletion: %#v %v", got, err)
	}
}

func TestCustomStationsPersistAndValidate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "yakker", "stations.json")
	bundled := []Station{{"id": "stock"}}
	id, err := NewCustomStationID()
	if err != nil {
		t.Fatal(err)
	}
	station := CustomStation{ID: id, Name: "<b>Radio</b>", StreamURL: "https://example.test/audio", City: "Boston", Country: "US"}
	if err := SaveCustomStations(path, []CustomStation{station}, bundled); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("mode: %v %v", info, err)
	}
	got, err := LoadCustomStations(path, bundled)
	if err != nil || len(got) != 1 || got[0] != station {
		t.Fatalf("round trip: %#v %v", got, err)
	}
	merged := MergeCustomStations(bundled, got)
	if len(merged) != 2 || merged[1]["id"] != id || merged[1]["subtitle"] != "Boston · US" || merged[1]["custom"] != true {
		t.Fatalf("merge: %#v", merged)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []CustomStation{
		{ID: id, Name: "", StreamURL: station.StreamURL},
		{ID: id, Name: "Name", StreamURL: "file:///tmp/a"},
		{ID: id, Name: strings.Repeat("x", 161), StreamURL: station.StreamURL},
		{ID: "stock", Name: "Name", StreamURL: station.StreamURL},
		{ID: id, Name: "Name", StreamURL: station.StreamURL, Website: "javascript:alert(1)"},
	} {
		if err := SaveCustomStations(path, []CustomStation{bad}, bundled); err == nil {
			t.Fatalf("accepted %#v", bad)
		}
		after, _ := os.ReadFile(path)
		if string(after) != string(before) {
			t.Fatal("invalid update changed file")
		}
	}
	if err := SaveCustomStations(path, []CustomStation{station, station}, bundled); err == nil {
		t.Fatal("accepted duplicate ID")
	}
	if err := SaveCustomStations(path, nil, bundled); err != nil {
		t.Fatal(err)
	}
	got, err = LoadCustomStations(path, bundled)
	if err != nil || len(got) != 0 {
		t.Fatalf("delete: %#v %v", got, err)
	}
}

func TestCustomStationsCorruptFileNeverOverwritten(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stations.json")
	for _, data := range []string{"{broken", "null", "[] {}", `[ {"id":"bad", "name":"x", "streamUrl":"https://example.test"} ]`, `[ {"unknown":true} ]`, strings.Repeat(" ", maxCustomFileBytes+1)} {
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadCustomStations(path, nil); err == nil {
			t.Fatalf("accepted %q", data[:min(len(data), 60)])
		}
		if err := SaveCustomStations(path, nil, nil); err == nil {
			t.Fatal("overwrote invalid file")
		}
		after, err := os.ReadFile(path)
		if err != nil || string(after) != data {
			t.Fatal("invalid file changed")
		}
	}
}

func TestCustomStationsWriteFailureAndLimits(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "block", "stations.json")
	if err := os.WriteFile(filepath.Join(dir, "block"), []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := SaveCustomStations(path, nil, nil); err == nil {
		t.Fatal("expected write failure")
	}
	if err := validateCustomStations(make([]CustomStation, maxCustomStations+1), nil); err == nil {
		t.Fatal("accepted oversized collection")
	}
	id, err := NewCustomStationID()
	if err != nil {
		t.Fatal(err)
	}
	if err := validateCustomStations([]CustomStation{{ID: id, Name: "x", StreamURL: "https://example.test"}}, []Station{{"id": id}}); err == nil {
		t.Fatal("accepted bundled ID collision")
	}
}
