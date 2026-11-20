package tool

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const maxTerminalPreferenceBytes = 4096

type terminalPreferences struct {
	StationID string `json:"stationId"`
}

func terminalPreferencePath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "yakker", "terminal.json"), nil
}

// Invalid or missing preferences leave the station unselected. A bounded read
// prevents a damaged preferences file from consuming unbounded memory.
func loadTerminalStation(path string) string {
	file, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxTerminalPreferenceBytes+1))
	var preferences terminalPreferences
	if err != nil || len(data) > maxTerminalPreferenceBytes || json.Unmarshal(data, &preferences) != nil {
		return ""
	}
	return preferences.StationID
}

func saveTerminalStation(path, id string) error {
	if id == "" || len(id) > 512 || strings.TrimSpace(id) != id {
		return errors.New("invalid terminal station preference")
	}
	data, err := json.Marshal(terminalPreferences{StationID: id})
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".terminal-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(append(data, '\n')); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
