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
		"talksport": true, "talksport-2": true, "bbc-radio-5-live": true, "off-the-ball": true,
	}
	if len(stations) != len(want) || stations[0]["id"] != "wbz-fm" {
		t.Fatal("expected the full catalogue with the existing WBZ default preserved")
	}
	for _, station := range stations {
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
