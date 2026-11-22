package radio

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestBundledStationCatalogue(t *testing.T) {
	stations, err := LoadStations(stationFile)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{
		"wbz-fm": true, "weei-fm": true, "wscr": true, "wxyt-fm": true, "espn-new-york": true,
		"wfan": true, "wip-fm": true, "kdka-fm": true, "tsn-1050": true, "klac": true,
		"krld-fm": true, "kfan": true, "kiro-am": true, "sportsnet-590": true, "tsn-690": true,
		"wbns-fm": true, "wkrk-fm": true, "kwfn-fm": true, "wzgc-fm": true, "kkfn-fm": true,
		"talksport": true, "talksport-2": true, "bbc-radio-5-live": true, "off-the-ball": true,
		"wbz-am": true, "wbur": true, "wins": true, "wnyc-fm": true, "knx-am": true,
		"kpcc": true, "wbbm-am": true, "kyw-am": true, "wwj-am": true, "kcfr": true,
		"know": true, "kuow": true, "kpbs": true,
	}
	categories := map[string]int{}
	if len(stations) != len(want) || stations[0]["id"] != "wbz-fm" {
		t.Fatal("expected the full catalogue in its established order")
	}
	for _, station := range stations {
		category, _ := station["category"].(string)
		if category != "sports" && category != "news" {
			t.Errorf("bundled station %s needs a Sports or News category", station["id"])
		}
		categories[category]++
		if !want[station["id"].(string)] {
			t.Errorf("unexpected station %s", station["id"])
		}
		delete(want, station["id"].(string))
		city, _ := station["city"].(string)
		country, _ := station["country"].(string)
		artwork, _ := station["artwork"].(string)
		if city == "" || (country != "US" && country != "CA" && country != "GB" && country != "IE") || !filepath.IsLocal(artwork) || filepath.Dir(artwork) != "assets" {
			t.Errorf("station %s requires a city, country and bundled artwork", station["id"])
			continue
		}
		info, err := os.Stat(filepath.Join(filepath.Dir(stationFile), artwork))
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > 512*1024 {
			t.Errorf("station %s artwork is missing, empty or oversized: %v", station["id"], err)
		}
	}
	if len(want) > 0 {
		t.Errorf("missing requested stations: %v", want)
	}
	if categories["sports"] != 24 || categories["news"] != 13 {
		t.Fatalf("wrong curated category coverage: %v", categories)
	}
}

func TestExternalStationCategoriesRemainOptional(t *testing.T) {
	path := filepath.Join(t.TempDir(), "stations.json")
	for _, category := range []string{"", `,"category":"news"`, `,"category":"sports"`} {
		data := `[{"id":"legacy","name":"My station","subtitle":"Local","streamUrl":"https://example.test/live"` + category + `}]`
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadStations(path); err != nil {
			t.Fatal("valid external catalogue rejected", err)
		}
	}
	for _, category := range []string{`"music"`, `true`, `[]`, `{}`, `null`} {
		data := `[{"id":"bad","name":"Bad category","subtitle":"Local","streamUrl":"https://example.test/live","category":` + category + `}]`
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadStations(path); err == nil {
			t.Fatal("invalid category accepted", category)
		}
	}
}

func TestStationSelectionStartsEmptyAndConfigurePreservesOrClears(t *testing.T) {
	h := newEmptyHarness(t, Config{}, false)
	initial := h.barrier()
	if len(initial.Station) != 0 || initial.Wanted {
		t.Fatalf("fresh controller selected a station: %+v", initial)
	}
	serial := h.send("play")
	state := h.wait(func(s Status) bool { return s.Serial == serial })
	if state.Error == "" || state.Wanted || state.PlayerPID != 0 {
		t.Fatalf("play without a station: %+v", state)
	}
	serial = h.send("configure", "stationId", "wfan")
	h.wait(func(s Status) bool { return s.Serial == serial && s.Station["id"] == "wfan" })
	serial = h.send("configure", "bufferMinutes", 5)
	state = h.wait(func(s Status) bool { return s.Serial == serial })
	if state.Station["id"] != "wfan" {
		t.Fatalf("omitted station cleared selection: %+v", state)
	}
	h.play()
	serial = h.send("configure", "stationId", "")
	state = h.wait(func(s Status) bool { return s.Serial == serial })
	if len(state.Station) != 0 || state.Wanted || state.PlayerPID != 0 {
		t.Fatalf("clearing station did not stop live playback: %+v", state)
	}
	serial = h.send("configure", "stationId", "missing-saved-station")
	state = h.wait(func(s Status) bool { return s.Serial == serial })
	if len(state.Station) != 0 {
		t.Fatalf("unknown station selected another broadcaster: %+v", state)
	}
}

func TestSelectingStationFromStoppedRecordingDoesNotPlay(t *testing.T) {
	r := &controller{stations: []Station{{"id": "one", "name": "One", "streamUrl": "https://example.test"}}, state: Status{State: "stopped", PlaybackKind: "recording", Station: Station{}, RecordingID: "recording"}}
	if _, err := r.command([]byte(`{"action":"configure","stationId":"one"}`)); err != nil {
		t.Fatal(err)
	}
	if r.state.PlaybackKind != "live" || r.state.Station["id"] != "one" || r.state.Wanted || r.player != nil || r.state.State != "stopped" {
		t.Fatalf("selecting a station started playback: %+v", r.state)
	}
}

func TestStationSwitchPreservesPlaybackIntentAndPreferences(t *testing.T) {
	h := newHarness(t, Config{}, false)
	h.send("volume", "value", 43)
	h.send("mute", "value", true)
	serial := h.send("configure", "stationId", "wfan")
	stopped := h.wait(func(s Status) bool { return s.Serial == serial })
	if stopped.State != "stopped" || stopped.Wanted || stopped.PlayerPID != 0 || stopped.Station["id"] != "wfan" || stopped.Volume != 43 || !stopped.Muted {
		t.Fatalf("switch while stopped: %+v", stopped)
	}
	first := h.play()
	serial = h.send("configure", "stationId", "tsn-1050")
	second := h.wait(func(s Status) bool { return s.Serial == serial && s.State == "playing" })
	if !second.Wanted || second.Station["id"] != "tsn-1050" || second.PlayerPID == first.PlayerPID || second.Volume != 43 || !second.Muted {
		t.Fatalf("switch during playback: %+v", second)
	}
	if err := syscall.Kill(first.PlayerPID, 0); err == nil {
		t.Fatal("previous station's player survived switching")
	}
	h.stop()
	serial = h.send("invalid-action")
	h.wait(func(s Status) bool { return s.Serial == serial && s.Error != "" })
	serial = h.send("configure", "stationId", "wbz-fm")
	final := h.wait(func(s Status) bool { return s.Serial == serial })
	if final.State != "stopped" || final.Wanted || final.PlayerPID != 0 || final.Error != "" || final.Title != "" {
		t.Fatalf("new stopped station retained previous error/title: %+v", final)
	}
}
