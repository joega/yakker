package tool

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/joega/yakker/internal/radio"
)

type listenOptions struct {
	station, streamURL, stationFile string
	volume                          int
	bufferMinutes                   int
	muted, list                     bool
}

const listenCommands = "Commands: play/resume, pause, stop, back [seconds], forward [seconds], live, buffer 0|5|15|30, volume 0–100, mute (toggle), unmute, status, help, quit.\n"

func parseListenOptions(args []string, output io.Writer) (listenOptions, error) {
	return parsePlaybackOptions(args, output, "listen")
}

func parsePlaybackOptions(args []string, output io.Writer, mode string) (listenOptions, error) {
	var options listenOptions
	flags := flag.NewFlagSet(mode, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&options.station, "station", "", "station ID from stations.json (default: first station)")
	flags.StringVar(&options.streamURL, "url", "", "HTTP(S) stream URL instead of a configured station")
	flags.StringVar(&options.stationFile, "stations", "", "alternate stations.json file")
	flags.IntVar(&options.bufferMinutes, "buffer", 0, "DVR buffer in minutes: 0 (live only), 5, 15 or 30")
	flags.IntVar(&options.volume, "volume", 60, "initial volume, 0–100")
	flags.BoolVar(&options.muted, "muted", false, "start muted")
	flags.BoolVar(&options.list, "list-stations", false, "list configured station IDs and exit")
	flags.Usage = func() {
		fmt.Fprintf(output, "Usage: yakker %s [--station ID | --url URL] [--volume 60] [--muted] [--buffer 0|5|15|30]\n", mode)
		flags.SetOutput(output)
		flags.PrintDefaults()
		flags.SetOutput(io.Discard)
		if mode == "tui" {
			fmt.Fprintln(output, "\nKeys: space play/stop, p pause/resume, [ / ] rewind/forward 30s, g live, left/right volume, up/down select, enter tune, m mute, r retry, ? help, q quit.")
		} else {
			fmt.Fprint(output, "\n"+listenCommands+"Each command is followed by Enter. Ctrl+C or EOF also exits.\n")
		}
	}
	if err := flags.Parse(args); err != nil {
		return options, err
	}
	if flags.NArg() != 0 {
		return options, fmt.Errorf("unexpected argument %q; use --station or --url", flags.Arg(0))
	}
	if options.bufferMinutes != 0 && options.bufferMinutes != 5 && options.bufferMinutes != 15 && options.bufferMinutes != 30 {
		return options, errors.New("buffer must be 0, 5, 15 or 30 minutes")
	}
	if options.volume < 0 || options.volume > 100 {
		return options, errors.New("volume must be an integer from 0 to 100")
	}
	if options.streamURL != "" && (options.station != "" || options.list || options.stationFile != "") {
		return options, errors.New("--url cannot be combined with --station, --stations, or --list-stations")
	}
	if options.streamURL != "" {
		u, err := url.Parse(options.streamURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
			return options, errors.New("stream URL must use HTTP or HTTPS")
		}
	}
	return options, nil
}

// Listen runs a foreground player independently of the installed widget. The
// audio environment stays intact; only the controller's lock/socket is isolated.
func Listen(ctx context.Context, root string, args []string, input io.Reader, output, logs io.Writer) error {
	options, err := parseListenOptions(args, output)
	if errors.Is(err, flag.ErrHelp) {
		return nil
	}
	if err != nil {
		return err
	}
	return listen(ctx, root, options, radio.Config{}, input, output, logs, radio.Run)
}

type controllerRunner func(context.Context, radio.Config, io.Reader, io.Writer, io.Writer) error

func listen(ctx context.Context, root string, options listenOptions, cfg radio.Config, input io.Reader, output, logs io.Writer, run controllerRunner) error {
	if options.list {
		path := options.stationFile
		if path == "" {
			path = filepath.Join(root, "stations.json")
		}
		loader := radio.LoadStationCatalog
		if options.stationFile != "" {
			loader = radio.LoadStations
		}
		stations, err := loader(path)
		if err != nil {
			return err
		}
		for _, station := range stations {
			fmt.Fprintf(output, "%s\t%s\n", terminalText(station["id"].(string)), terminalText(station["name"].(string)))
		}
		return nil
	}
	setup, err := preparePlayback(root, options, cfg)
	if err != nil {
		return err
	}
	defer setup.close()
	selected := setup.selected
	cfg = setup.cfg
	fmt.Fprintf(output, "Listening to %s at %d%% volume.\n%s", terminalText(selected["name"].(string)), options.volume, listenCommands)
	return listenSession(ctx, cfg, selected["id"].(string), options, input, output, logs, run)
}

type playbackSetup struct {
	cfg      radio.Config
	stations []radio.Station
	selected radio.Station
}

func (p *playbackSetup) close() { _ = os.RemoveAll(p.cfg.RuntimeBase) }

func preparePlayback(root string, options listenOptions, cfg radio.Config) (*playbackSetup, error) {
	stationFile := options.stationFile
	if stationFile == "" {
		stationFile = filepath.Join(root, "stations.json")
	}
	var stations []radio.Station
	var err error
	if options.streamURL != "" {
		stations = []radio.Station{{"id": "cli", "name": "CLI test stream", "subtitle": "Standalone radio", "streamUrl": options.streamURL}}
	} else {
		loader := radio.LoadStationCatalog
		if options.stationFile != "" {
			loader = radio.LoadStations
		}
		stations, err = loader(stationFile)
		if err != nil {
			return nil, err
		}
	}

	selected := stations[0]
	if options.station != "" {
		selected = nil
		for _, station := range stations {
			if station["id"] == options.station {
				selected = station
				break
			}
		}
		if selected == nil {
			return nil, fmt.Errorf("unknown station %q; use listen --list-stations", options.station)
		}
	}
	// A short, private directory also stays within Linux's Unix-socket path limit.
	base, err := os.MkdirTemp("/tmp", "yakker-cli-")
	if err != nil {
		return nil, err
	}

	ready := false
	defer func() {
		if !ready {
			_ = os.RemoveAll(base)
		}
	}()
	if options.streamURL != "" || options.stationFile == "" {
		stationFile = filepath.Join(base, "stations.json")
		data, err := json.Marshal(stations)
		if err != nil {
			return nil, err
		}
		if err = os.WriteFile(stationFile, data, 0600); err != nil {
			return nil, err
		}
	}
	cfg.DVRWindow = time.Duration(options.bufferMinutes) * time.Minute
	cfg.RuntimeBase = base
	cfg.StationFile = stationFile
	ready = true
	return &playbackSetup{cfg: cfg, stations: stations, selected: selected}, nil
}

type consoleLine struct {
	text string
	err  error
	eof  bool
}
type statusEvent struct {
	status radio.Status
	err    error
}

func listenSession(parent context.Context, cfg radio.Config, stationID string, options listenOptions, input io.Reader, output, logs io.Writer, run controllerRunner) (result error) {
	ctx, cancel := context.WithCancel(parent)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	finished := make(chan struct{})
	var controllerErr error
	go func() {
		controllerErr = run(ctx, cfg, inR, outW, logs)
		_ = inR.CloseWithError(controllerErr)
		_ = outW.CloseWithError(controllerErr)
		close(finished)
	}()
	defer func() {
		cancel()
		_ = inW.Close()
		<-finished // Wait for mpv to be terminated and reaped before deleting runtime.
		_ = outR.Close()
		if controllerErr != nil && !errors.Is(result, controllerErr) {
			result = errors.Join(result, controllerErr)
		}
		if result == nil {
			fmt.Fprintln(output, "\nStopped.")
		}
	}()
	states := make(chan statusEvent, 32)
	go func() {
		defer close(states)
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(make([]byte, 4096), 16*1024*1024)
		for scanner.Scan() {
			var status radio.Status
			err := json.Unmarshal(scanner.Bytes(), &status)
			select {
			case states <- statusEvent{status: status, err: err}:
			case <-ctx.Done():
				// Keep draining until Run finishes, including any final publication.
				_, _ = io.Copy(io.Discard, outR)
				return
			}
			if err != nil {
				_, _ = io.Copy(io.Discard, outR)
				return
			}
		}
		if err := scanner.Err(); err != nil {
			select {
			case states <- statusEvent{err: err}:
			case <-ctx.Done():
			}
		}
	}()
	lines := make(chan consoleLine)
	go func() {
		scanner := bufio.NewScanner(input)
		scanner.Buffer(make([]byte, 4096), 65536)
		for scanner.Scan() {
			select {
			case lines <- consoleLine{text: scanner.Text()}:
			case <-ctx.Done():
				return
			}
		}
		select {
		case lines <- consoleLine{err: scanner.Err(), eof: true}:
		case <-ctx.Done():
		}
	}()
	var serial, muteSerial int64
	muted := options.muted
	send := func(action string, fields map[string]any) error {
		serial++
		if fields == nil {
			fields = map[string]any{}
		}
		fields["action"] = action
		fields["serial"] = serial
		if action == "mute" {
			muteSerial = serial
		}
		return json.NewEncoder(inW).Encode(fields)
	}
	// Set all preferences before Play: there is no momentary default-volume audio.
	for _, command := range []struct {
		action string
		fields map[string]any
	}{
		{"configure", map[string]any{"stationId": stationID}},
		{"volume", map[string]any{"value": options.volume}},
		{"mute", map[string]any{"value": options.muted}},
		{"play", nil},
	} {
		if err := send(command.action, command.fields); err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
	}
	lastStatus := ""
	replies := make(map[int64]bool)
	for {
		select {
		case <-ctx.Done():
			return nil
		case event, ok := <-states:
			if !ok {
				return nil
			} // Deferred wait propagates any controller failure.
			if event.err != nil {
				return event.err
			}
			state := event.status
			if state.Serial >= muteSerial {
				muted = state.Muted
			}
			// Ignore initialization acknowledgements; render once Play was received.
			if state.Serial < 4 {
				continue
			}
			text := formatListenStatus(state)
			force := replies[state.Serial]
			delete(replies, state.Serial)
			if text != lastStatus || force {
				display := text
				if force && state.DVR {
					display += "\n" + formatDVRStatus(state)
				}
				fmt.Fprintf(output, "\n%s\nyakker> ", display)
				lastStatus = text
			}
		case line := <-lines:
			if line.eof {
				return line.err
			}
			fields := strings.Fields(line.text)
			if len(fields) == 0 {
				fmt.Fprint(output, "yakker> ")
				continue
			}
			command := strings.ToLower(fields[0])
			if command == "quit" && len(fields) == 1 {
				return nil
			}
			if command == "help" && len(fields) == 1 {
				fmt.Fprint(output, listenCommands+"yakker> ")
				continue
			}
			var action string
			var values map[string]any
			switch {
			case (command == "play" || command == "stop" || command == "status" || command == "pause" || command == "live" || command == "resume") && len(fields) == 1:
				action = command
				if action == "resume" {
					action = "play"
				}
			case (command == "back" || command == "forward") && len(fields) <= 2:
				seconds := 30.0
				var err error
				if len(fields) == 2 {
					seconds, err = strconv.ParseFloat(fields[1], 64)
				}
				if err != nil || seconds <= 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
					fmt.Fprint(output, "Seek seconds must be a positive finite number.\nyakker> ")
					continue
				}
				if command == "back" {
					seconds = -seconds
				}
				action = "skip"
				values = map[string]any{"value": seconds}
			case command == "buffer" && len(fields) == 2:
				minutes, err := strconv.Atoi(fields[1])
				if err != nil || (minutes != 0 && minutes != 5 && minutes != 15 && minutes != 30) {
					fmt.Fprint(output, "Buffer must be 0, 5, 15 or 30 minutes.\nyakker> ")
					continue
				}
				action = "configure"
				values = map[string]any{"stationId": stationID, "bufferMinutes": minutes}
			case command == "volume" && len(fields) == 2:
				volume, err := strconv.Atoi(fields[1])
				if err != nil || volume < 0 || volume > 100 {
					fmt.Fprint(output, "Volume must be an integer from 0 to 100.\nyakker> ")
					continue
				}
				action = "volume"
				values = map[string]any{"value": volume}
			case (command == "mute" || command == "unmute") && len(fields) == 1:
				if command == "mute" {
					muted = !muted
				} else {
					muted = false
				}
				action = "mute"
				values = map[string]any{"value": muted}
			default:
				fmt.Fprint(output, "Unknown command or arguments. "+listenCommands+"yakker> ")
				continue
			}
			if err := send(action, values); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				return err
			}
			replies[serial] = true
		}
	}
}

func formatListenStatus(s radio.Status) string {
	name, _ := s.Station["name"].(string)
	state := s.State
	switch state {
	case "playing":
		state = "Playing"
		if s.DVR && s.BufferEnd-s.Position > 3 {
			state += " (behind live)"
		}
	case "paused":
		state = "Paused"
	case "connecting":
		state = "Connecting"
	case "stopped":
		state = "Stopped"
	case "error":
		state = "Unable to play"
	case "retrying":
		state = fmt.Sprintf("Reconnecting in %gs (attempt %d/5)", s.RetryDelay, s.Retry)
	}
	text := fmt.Sprintf("%s · %s · Volume %d%%", terminalText(name), state, s.Volume)
	if s.Muted {
		text += " · Muted"
	}
	if s.Title != "" && (!s.DVR || (!s.Paused && s.BufferEnd-s.Position <= 3)) {
		text += " · " + terminalText(s.Title)
	}
	if s.Error != "" {
		text += "\nPlayback error: " + terminalText(s.Error)
	}
	return text
}

// Network metadata and station names must not inject terminal control sequences.
func terminalText(text string) string {
	return strings.Map(func(r rune) rune {
		if r < 32 || (r >= 127 && r <= 159) {
			return ' '
		}
		return r
	}, text)
}

func playbackClock(seconds float64) string {
	value := int(math.Max(0, seconds))
	return fmt.Sprintf("%d:%02d", value/60, value%60)
}
func formatDVRStatus(s radio.Status) string {
	if !s.DVR {
		if s.BufferMinutes == 0 && !s.TemporaryBuffer {
			return "Live only"
		}
		return "Building buffer…"
	}
	lag := math.Max(0, s.BufferEnd-s.Position)
	label := "Live"
	if lag > 3 {
		label = playbackClock(lag) + " behind live"
	}
	if s.Paused {
		label = "Paused · " + playbackClock(lag) + " behind live"
	}
	label += " · " + playbackClock(s.BufferEnd-s.BufferStart) + " available"
	if s.TemporaryBuffer {
		label += " · Temporary 15-minute buffer"
	}
	if s.BufferExpired {
		label += " · Older audio expired"
	}
	return label
}
