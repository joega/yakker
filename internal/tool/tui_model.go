package tool

import (
	"fmt"

	tea "charm.land/bubbletea/v2"
	"github.com/joega/yakker/internal/radio"
)

type tuiStatusMsg statusEvent
type tuiClosedMsg struct{}
type tuiSend func(string, map[string]any) (int64, error)

type tuiModel struct {
	stations                                              []radio.Station
	cursor                                                int
	target                                                string
	status                                                radio.Status
	volume                                                int
	muted, wanted                                         bool
	paused                                                bool
	pauseSerial                                           int64
	volumeSerial, muteSerial, intentSerial, stationSerial int64
	width, height                                         int
	dark, help, ready                                     bool
	notice                                                string
	fatal                                                 error
	send                                                  tuiSend
	states                                                <-chan statusEvent
}

func newTUIModel(stations []radio.Station, selected string, options listenOptions, send tuiSend, states <-chan statusEvent) tuiModel {
	cursor := 0
	for i, s := range stations {
		if s["id"] == selected {
			cursor = i
		}
	}
	return tuiModel{stations: stations, cursor: cursor, target: selected, volume: options.volume, muted: options.muted, wanted: true,
		volumeSerial: 2, muteSerial: 3, intentSerial: 4, stationSerial: 4, width: 80, height: 24, dark: true, send: send, states: states,
		status: radio.Status{State: "connecting", Station: stations[cursor], Volume: options.volume, Muted: options.muted}}
}

func (m tuiModel) Init() tea.Cmd { return tea.Batch(m.waitStatus(), tea.RequestBackgroundColor) }
func (m tuiModel) waitStatus() tea.Cmd {
	return func() tea.Msg {
		event, ok := <-m.states
		if !ok {
			return tuiClosedMsg{}
		}
		return tuiStatusMsg(event)
	}
}
func (m *tuiModel) command(action string, fields map[string]any) (int64, bool) {
	serial, err := m.send(action, fields)
	if err != nil {
		m.notice = err.Error()
		return 0, false
	}
	m.notice = ""
	return serial, true
}
func (m *tuiModel) setWanted(wanted bool) {
	action := "stop"
	if wanted {
		action = "play"
	}
	if serial, ok := m.command(action, nil); ok {
		m.intentSerial = serial
		m.wanted = wanted
		if !wanted {
			m.paused = false
			m.pauseSerial = serial
		}
	}
}
func (m *tuiModel) setVolume(volume int) {
	volume = max(0, min(100, volume))
	if volume == m.volume {
		return
	}
	if serial, ok := m.command("volume", map[string]any{"value": volume}); ok {
		m.volumeSerial = serial
		m.volume = volume
	}
}
func (m *tuiModel) tune() {
	station := m.stations[m.cursor]["id"].(string)
	serial, ok := m.command("configure", map[string]any{"stationId": station})
	if !ok {
		return
	}
	// Configure can restart an active player; fence its old status immediately.
	m.target = station
	m.stationSerial = serial
	m.setWanted(true)
	if m.intentSerial > m.stationSerial {
		m.stationSerial = m.intentSerial
	}
}

func (m tuiModel) Update(message tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := message.(type) {
	case tea.WindowSizeMsg:
		m.width = max(1, msg.Width)
		m.height = max(1, msg.Height)
	case tea.BackgroundColorMsg:
		m.dark = msg.IsDark()
	case tuiClosedMsg:
		return m, tea.Quit
	case tuiStatusMsg:
		event := statusEvent(msg)
		if event.err != nil {
			m.fatal = event.err
			return m, tea.Quit
		}
		s := event.status
		if s.Serial >= 4 {
			m.ready = true
			if s.Serial >= m.status.Serial {
				m.status = s
			}
			if s.Serial >= m.volumeSerial {
				m.volume = s.Volume
			}
			if s.Serial >= m.muteSerial {
				m.muted = s.Muted
			}
			if s.Serial >= m.pauseSerial {
				m.paused = s.Paused
			}
			if s.Serial >= m.intentSerial {
				m.wanted = s.Wanted
			}
		}
		return m, m.waitStatus()
	case tea.KeyPressMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.help = !m.help
		case "up", "k":
			m.cursor = max(0, m.cursor-1)
		case "down", "j":
			m.cursor = min(len(m.stations)-1, m.cursor+1)
		case "home":
			m.cursor = 0
		case "end":
			m.cursor = len(m.stations) - 1
		case "enter":
			m.tune()
		case "p":
			if m.status.BufferMinutes == 0 {
				break
			}
			if !m.wanted {
				m.setWanted(true)
			} else if serial, ok := m.command(map[bool]string{true: "play", false: "pause"}[m.paused], nil); ok {
				m.paused = !m.paused
				m.pauseSerial = serial
			}
		case "[", "]":
			seconds := -30.0
			if msg.String() == "]" {
				seconds = 30
			}
			m.command("skip", map[string]any{"value": seconds})
		case "g":
			if serial, ok := m.command("live", nil); ok {
				m.pauseSerial = serial
				m.paused = false
			}
		case "space":
			m.setWanted(!m.wanted)
		case "s":
			m.setWanted(false)
		case "left", "h", "-":
			m.setVolume(m.volume - 5)
		case "right", "l", "+", "=":
			m.setVolume(m.volume + 5)
		case "m":
			if serial, ok := m.command("mute", map[string]any{"value": !m.muted}); ok {
				m.muted = !m.muted
				m.muteSerial = serial
			}
		case "r":
			m.setWanted(false)
			m.setWanted(true)
		}
	}
	return m, nil
}

func (m tuiModel) pendingStation() bool { return !m.ready || m.status.Serial < m.stationSerial }
func (m tuiModel) displayStation() radio.Station {
	if m.pendingStation() {
		for _, station := range m.stations {
			if station["id"] == m.target {
				return station
			}
		}
	}
	return m.status.Station
}
func (m tuiModel) badge() (string, string) {
	if m.pendingStation() {
		return "◌ CONNECTING", "pending"
	}
	if m.paused {
		return "Ⅱ PAUSED", "pending"
	}
	switch m.status.State {
	case "playing":
		if m.status.DVR && m.status.BufferEnd-m.status.Position > 3 {
			return "● DELAYED", "pending"
		}
		return "● LIVE", "live"
	case "paused":
		return "Ⅱ PAUSED", "pending"
	case "connecting":
		return "◌ CONNECTING", "pending"
	case "retrying":
		return "◌ RECONNECTING", "pending"
	case "error":
		return "! UNAVAILABLE", "error"
	default:
		return "○ STOPPED", "stopped"
	}
}
func (m tuiModel) playbackDetail() string {
	if m.notice != "" {
		return terminalText(m.notice)
	}
	if m.pendingStation() {
		return "Tuning station…"
	}
	if m.status.State == "retrying" {
		detail := fmt.Sprintf("Retry %d of 5 · reconnecting in %gs", m.status.Retry, m.status.RetryDelay)
		if m.status.Error != "" {
			detail += " · " + terminalText(m.status.Error)
		}
		return detail
	}
	if m.status.Error != "" {
		return terminalText(m.status.Error)
	}
	if m.status.DVR {
		return formatDVRStatus(m.status)
	}
	if m.status.Title != "" {
		return terminalText(m.status.Title)
	}
	if m.status.State == "connecting" {
		return "Connecting to the live stream…"
	}
	if m.status.State == "stopped" {
		return "Press Space to connect to the live stream."
	}
	return "Live station stream"
}

// Check the Bubble Tea model contract at compile time.
var _ tea.Model = tuiModel{}
