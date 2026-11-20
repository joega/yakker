package tool

import (
	"fmt"
	"strings"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/joega/yakker/internal/radio"
)

type radioStyles struct{ ink, dim, accent, live, warning, selection, border lipgloss.Style }

func makeRadioStyles(dark bool) radioStyles {
	ink, dim, accent, live, warning, selection, border := "#E3E5E2", "#8E9798", "#E0B772", "#8DC19B", "#DD8E80", "#292C2A", "#414846"
	if !dark {
		ink, dim, accent, live, warning, selection, border = "#26332F", "#65716C", "#875A19", "#317344", "#A83D31", "#F1EADD", "#C9D1CB"
	}
	return radioStyles{
		ink:       lipgloss.NewStyle().Foreground(lipgloss.Color(ink)),
		dim:       lipgloss.NewStyle().Foreground(lipgloss.Color(dim)),
		accent:    lipgloss.NewStyle().Foreground(lipgloss.Color(accent)),
		live:      lipgloss.NewStyle().Foreground(lipgloss.Color(live)),
		warning:   lipgloss.NewStyle().Foreground(lipgloss.Color(warning)),
		selection: lipgloss.NewStyle().Foreground(lipgloss.Color(accent)).Background(lipgloss.Color(selection)).Bold(true),
		border:    lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(lipgloss.Color(border)),
	}
}
func (s radioStyles) badge(text, kind string) string {
	switch kind {
	case "live":
		return s.live.Bold(true).Render(text)
	case "error":
		return s.warning.Bold(true).Render(text)
	case "pending":
		return s.accent.Render(text)
	default:
		return s.dim.Render(text)
	}
}
func tuiClip(text string, width int) string {
	return ansi.Truncate(terminalText(text), max(1, width), "…")
}
func stationString(station radio.Station, key string) string {
	value, _ := station[key].(string)
	return value
}

func (m tuiModel) View() tea.View {
	styles := makeRadioStyles(m.dark)
	var content string
	switch {
	case m.width < 40 || m.height < 14:
		content = m.tinyView(styles)
	case m.height < 20 || (m.help && m.height < 22):
		content = m.compactView(styles)
	default:
		content = m.cardView(styles)
	}
	view := tea.NewView(content)
	view.AltScreen = true
	view.WindowTitle = "Yakker"
	return view
}
func (m tuiModel) volumeBar(styles radioStyles, width int) string {
	cells := max(4, min(28, width-15))
	fill := max(0, min(cells, (m.volume*cells+50)/100))
	filled := styles.accent.Render(strings.Repeat("━", fill))
	if m.muted {
		filled = styles.dim.Render(strings.Repeat("━", fill))
	}
	return styles.dim.Render("VOLUME  ") + filled + styles.dim.Render(strings.Repeat("─", cells-fill)) + styles.ink.Bold(true).Render(fmt.Sprintf(" %d%%", m.volume))
}
func (m tuiModel) controls(styles radioStyles) string {
	play := "▶ Play"
	if m.wanted {
		play = "■ Stop"
	}
	mute := "Sound on"
	if m.muted {
		mute = "Muted"
	}
	return styles.ink.Bold(true).Render(play) + styles.dim.Render("  [space]        ") + styles.ink.Render(mute) + styles.dim.Render("  [m]")
}
func (m tuiModel) stationRow(index, width int, styles radioStyles) string {
	station := m.stations[index]
	cursor := "  "
	if index == m.cursor {
		cursor = "› "
	}
	active := "  "
	if station["id"] == m.status.Station["id"] && !m.pendingStation() {
		active = "● "
	}
	label := stationString(station, "name")
	if city := stationString(station, "city"); city != "" {
		label += " · " + city
	}
	text := cursor + active + tuiClip(label, max(1, width-4))
	if index == m.cursor {
		return styles.selection.Width(width).Render(text)
	}
	return styles.dim.Render(text)
}
func (m tuiModel) cardView(styles radioStyles) string {
	cardWidth := min(76, m.width-4)
	inner := cardWidth - 6
	badge, kind := m.badge()
	brand := styles.accent.Bold(true).Render("◉  YAKKER")
	right := styles.badge(badge, kind)
	header := brand + strings.Repeat(" ", max(1, inner-lipgloss.Width(brand)-lipgloss.Width(right))) + right
	station := m.displayStation()
	detail := m.playbackDetail()
	detailStyle := styles.dim
	if m.notice != "" || (!m.pendingStation() && m.status.Error != "") {
		detailStyle = styles.warning
	}
	details := strings.Split(ansi.Wrap(terminalText(detail), inner, ""), "\n")
	if len(details) > 2 {
		details = details[:2]
		details[1] = ansi.Truncate(details[1], inner-1, "") + "…"
	}
	for i := range details {
		details[i] = detailStyle.Render(details[i])
	}
	rows := []string{header, "", styles.ink.Bold(true).Render(tuiClip(stationString(station, "name"), inner)), styles.dim.Render(tuiClip(stationString(station, "subtitle"), inner)), "", strings.Join(details, "\n"), "", m.controls(styles), m.volumeBar(styles, inner), "", styles.dim.Render("STATIONS") + styles.dim.Render(fmt.Sprintf("  %d / %d", m.cursor+1, len(m.stations)))}
	footer := []string{
		styles.dim.Render("space play/stop   ←/→ volume   m mute   q quit"),
		styles.dim.Render("↑/↓ select station   enter tune   r retry   ? help"),
	}
	if inner < 50 {
		footer = []string{styles.dim.Render("space play/stop  ←/→ vol  m mute"), styles.dim.Render("↑/↓ select  enter tune  q quit")}
	}
	if m.help {
		footer = []string{
			styles.dim.Render("space / p  Play or stop"),
			styles.dim.Render("←/→ / ±    Volume by 5%   m  Mute"),
			styles.dim.Render("↑/↓ / j/k  Select   enter  Tune"),
			styles.dim.Render("r  Retry   ?  Close help   q / esc  Quit"),
		}
	}
	available := max(1, min(5, m.height-(16+len(details)+len(footer))))
	start := max(0, min(m.cursor-available/2, len(m.stations)-available))
	end := min(len(m.stations), start+available)
	for i := start; i < end; i++ {
		rows = append(rows, m.stationRow(i, inner, styles))
	}
	rows = append(rows, "")
	rows = append(rows, footer...)
	box := styles.border.Width(cardWidth).Padding(1, 2).Render(fitTUIRows(rows, inner))
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}
func (m tuiModel) compactView(styles radioStyles) string {
	cardWidth := min(70, m.width-2)
	inner := cardWidth - 4
	station := m.displayStation()
	badge, kind := m.badge()
	muteLabel := ""
	if m.muted {
		muteLabel = styles.dim.Render(" · Muted")
	}
	rows := []string{
		styles.accent.Bold(true).Render("YAKKER") + "  " + styles.badge(badge, kind) + muteLabel, "",
		styles.ink.Bold(true).Render(tuiClip(stationString(station, "name"), inner)),
		styles.dim.Render(tuiClip(stationString(station, "subtitle"), inner)), "",
		m.volumeBar(styles, inner), styles.dim.Render(tuiClip(m.playbackDetail(), inner)), "",
		m.stationRow(m.cursor, inner, styles),
		styles.dim.Render("space play/stop  ←/→ vol  m mute"),
		styles.dim.Render("↑/↓ select  enter tune  q quit"),
	}
	if m.help {
		rows = []string{rows[0], "", rows[2], m.volumeBar(styles, inner), "", styles.dim.Render("space / p  Play or stop"), styles.dim.Render("←/→ / ±  Volume   m  Mute"), styles.dim.Render("↑/↓ select   enter tune"), styles.dim.Render("r retry  ? close help  q quit")}
	}
	box := styles.border.Width(cardWidth).Padding(0, 1).Render(fitTUIRows(rows, inner))
	return lipgloss.Place(m.width, m.height, lipgloss.Center, lipgloss.Center, box)
}
func (m tuiModel) tinyView(styles radioStyles) string {
	badge, kind := m.badge()
	station := m.displayStation()
	muted := ""
	if m.muted {
		muted = " · Muted"
	}
	rows := []string{
		styles.accent.Bold(true).Render("YAKKER") + "  " + styles.badge(badge, kind),
		styles.ink.Bold(true).Render(tuiClip(stationString(station, "name"), m.width)),
		styles.ink.Render(fmt.Sprintf("Volume %d%%%s", m.volume, muted)),
		styles.dim.Render(tuiClip(m.playbackDetail(), m.width)),
		styles.accent.Render("› " + tuiClip(stationString(m.stations[m.cursor], "name"), m.width-2)),
		styles.dim.Render("space play/stop · ←/→ vol"),
		styles.dim.Render("↑/↓ select · enter tune"),
	}
	if m.help {
		rows = append(rows[:3], styles.dim.Render("space play/stop · m mute"), styles.dim.Render("↑/↓ select · enter tune"), styles.dim.Render("←/→ vol · r retry · ? help"))
	}
	limit := max(0, m.height-1)
	if len(rows) > limit {
		rows = rows[:limit]
	}
	footer := "m mute  ? help  q quit"
	if m.width < 22 {
		footer = "q quit"
	}
	rows = append(rows, styles.dim.Render(footer))
	for i := range rows {
		rows[i] = ansi.Truncate(rows[i], m.width, "")
	}
	return strings.Join(rows, "\n")
}

// Bound each styled line before Lip Gloss layout so it cannot wrap a footer,
// badge or incoming station metadata into an extra terminal row.
func fitTUIRows(rows []string, width int) string {
	var result []string
	for _, row := range rows {
		for _, line := range strings.Split(row, "\n") {
			result = append(result, ansi.Truncate(line, width, "…"))
		}
	}
	return strings.Join(result, "\n")
}
