package radio

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const maxCustomStations = 100
const maxCustomFileBytes = 256 * 1024

var customIDPattern = regexp.MustCompile(`^user-[0-9a-f]{32}$`)

// CustomStation is the complete user-editable representation on disk.
type CustomStation struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	StreamURL string `json:"streamUrl"`
	City      string `json:"city,omitempty"`
	Country   string `json:"country,omitempty"`
	Website   string `json:"website,omitempty"`
}

func CustomStationPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "yakker", "stations.json"), nil
}

// LoadStationCatalog merges the installed catalogue with the user's saved stations.
func LoadStationCatalog(path string) ([]Station, error) {
	bundled, err := LoadStations(path)
	if err != nil {
		return nil, err
	}
	customPath, err := CustomStationPath()
	if err != nil {
		return nil, err
	}
	custom, err := LoadCustomStations(customPath, bundled)
	if err != nil {
		return nil, err
	}
	return MergeCustomStations(bundled, custom), nil
}

func NewCustomStationID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	return "user-" + hex.EncodeToString(id[:]), nil
}

func validCustomText(s string, max int, required bool) bool {
	if !utf8.ValidString(s) || len(s) > max || (required && strings.TrimSpace(s) == "") {
		return false
	}
	for _, r := range s {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validHTTPURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Hostname() != "" && !strings.ContainsAny(s, " \t\r\n")
}

func validateCustomStations(custom []CustomStation, bundled []Station) error {
	if len(custom) > maxCustomStations {
		return fmt.Errorf("At most %d custom stations are allowed", maxCustomStations)
	}
	seen := make(map[string]bool, len(custom)+len(bundled))
	for _, s := range bundled {
		if id, ok := s["id"].(string); ok {
			seen[id] = true
		}
	}
	for _, s := range custom {
		if !customIDPattern.MatchString(s.ID) || seen[s.ID] {
			return errors.New("Invalid or duplicate custom station ID")
		}
		seen[s.ID] = true
		if !validCustomText(s.Name, 160, true) || !validCustomText(s.City, 100, false) || !validCustomText(s.Country, 100, false) {
			return errors.New("Invalid custom station name, city or country")
		}
		if !validCustomText(s.StreamURL, 2048, true) || !validHTTPURL(s.StreamURL) {
			return errors.New("Station stream URL must be an HTTP or HTTPS URL")
		}
		if s.Website != "" && (!validCustomText(s.Website, 2048, false) || !validHTTPURL(s.Website)) {
			return errors.New("Station website must be an HTTP or HTTPS URL")
		}
	}
	return nil
}

// LoadCustomStations treats an absent file as an empty library. Malformed or
// inaccessible data is always reported so callers can prevent overwriting it.
func LoadCustomStations(path string, bundled []Station) ([]CustomStation, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return []CustomStation{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("Read custom stations: %w", err)
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxCustomFileBytes+1))
	if err != nil {
		return nil, fmt.Errorf("Read custom stations: %w", err)
	}
	if len(data) > maxCustomFileBytes {
		return nil, errors.New("Custom stations file is too large")
	}
	var custom []CustomStation
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&custom); err != nil || custom == nil {
		return nil, errors.New("Invalid custom stations file")
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return nil, errors.New("Invalid custom stations file")
	}
	if err := validateCustomStations(custom, bundled); err != nil {
		return nil, fmt.Errorf("Invalid custom stations file: %w", err)
	}
	return custom, nil
}

// SaveCustomStations validates both the existing file and the proposed value
// before atomic replacement; callers publish new state only on success.
func SaveCustomStations(path string, custom []CustomStation, bundled []Station) error {
	if _, err := LoadCustomStations(path, bundled); err != nil {
		return err
	}
	if err := validateCustomStations(custom, bundled); err != nil {
		return err
	}
	if custom == nil {
		custom = []CustomStation{}
	}
	data, err := json.MarshalIndent(custom, "", "  ")
	if err != nil {
		return err
	}
	if len(data)+1 > maxCustomFileBytes {
		return errors.New("Custom stations file is too large")
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("Save custom stations: %w", err)
	}
	f, err := os.CreateTemp(dir, ".stations-*.tmp")
	if err != nil {
		return fmt.Errorf("Save custom stations: %w", err)
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(append(data, '\n'))
	}
	if err == nil {
		err = f.Sync()
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		return fmt.Errorf("Save custom stations: %w", err)
	}
	return nil
}

func MergeCustomStations(bundled []Station, custom []CustomStation) []Station {
	stations := append([]Station(nil), bundled...)
	for _, s := range custom {
		subtitle := strings.Join(nonempty(s.City, s.Country), " · ")
		if subtitle == "" {
			subtitle = "Custom station"
		}
		stations = append(stations, Station{"id": s.ID, "name": s.Name, "streamUrl": s.StreamURL, "subtitle": subtitle, "city": s.City, "country": s.Country, "website": s.Website, "custom": true})
	}
	return stations
}

func nonempty(values ...string) []string {
	var result []string
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			result = append(result, v)
		}
	}
	return result
}

func (r *controller) updateCustomStation(action string, data map[string]json.RawMessage) {
	r.state.CustomMutationSerial = r.state.Serial
	r.state.CustomMutationOK = false
	if r.customPath == "" || r.customLoadErr != nil {
		r.state.CustomStationError = "Custom stations are unavailable. Repair the file and restart Yakker."
		return
	}
	onDisk, err := LoadCustomStations(r.customPath, r.bundled)
	if err != nil || !reflect.DeepEqual(onDisk, r.custom) {
		r.state.CustomStationError = "Custom stations changed or could not be read. Restart Yakker before editing."
		return
	}
	next := append([]CustomStation{}, r.custom...)
	var id string
	if action == "upsertStation" {
		var station CustomStation
		decoder := json.NewDecoder(strings.NewReader(string(data["station"])))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&station); err != nil {
			r.state.CustomStationError = "Invalid station fields."
			return
		}
		id = station.ID
		if id == "" {
			id, err = NewCustomStationID()
			if err != nil {
				r.state.CustomStationError = "Could not create a station ID."
				return
			}
			station.ID = id
			next = append(next, station)
		} else {
			found := false
			for i := range next {
				if next[i].ID == id {
					next[i] = station
					found = true
					break
				}
			}
			if !found {
				r.state.CustomStationError = "The custom station no longer exists."
				return
			}
		}
	} else {
		if json.Unmarshal(data["stationId"], &id) != nil {
			r.state.CustomStationError = "Invalid station ID."
			return
		}
		found := false
		for i := range next {
			if next[i].ID == id {
				next = append(next[:i], next[i+1:]...)
				found = true
				break
			}
		}
		if !found {
			r.state.CustomStationError = "The custom station no longer exists."
			return
		}
	}
	if err := validateCustomStations(next, r.bundled); err != nil {
		r.state.CustomStationError = err.Error()
		return
	}
	if err := SaveCustomStations(r.customPath, next, r.bundled); err != nil {
		r.state.CustomStationError = "Could not save custom stations. Check the file and its permissions."
		return
	}
	oldStation := r.state.Station
	r.custom = next
	r.stations = MergeCustomStations(r.bundled, next)
	r.state.Stations = r.stations
	if oldStation["id"] == id {
		if action == "deleteStation" {
			r.stop()
			r.state.Station = r.stations[0]
		} else {
			for _, station := range r.stations {
				if station["id"] == id {
					urlChanged := oldStation["streamUrl"] != station["streamUrl"]
					wanted := r.state.Wanted
					if urlChanged {
						r.stop()
					}
					r.state.Station = station
					if urlChanged && wanted {
						r.play()
					}
					break
				}
			}
		}
	}
	r.state.CustomStationError = ""
	r.state.CustomMutationOK = true
}
