package tool

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/term"
	"github.com/joega/yakker/internal/radio"
)

// TUI hosts the same controller as listen, with a separate runtime and no shell
// IPC or persistent settings. The line-oriented CLI remains available as listen.
func TUI(ctx context.Context, root string, args []string, input io.Reader, output, logs io.Writer) error {
	options, err := parsePlaybackOptions(args, output, "tui")
	if err != nil {
		// The common flag parser has already printed help when requested.
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if options.list {
		return listen(ctx, root, options, radio.Config{}, input, output, logs, radio.Run)
	}
	in, ok := input.(*os.File)
	if !ok || !term.IsTerminal(in.Fd()) {
		return errors.New("tui requires an interactive terminal; use yakker listen for text or piped input")
	}
	out, ok := output.(*os.File)
	if !ok || !term.IsTerminal(out.Fd()) {
		return errors.New("tui requires terminal output; use yakker listen for redirected output")
	}
	setup, err := preparePlayback(root, options, radio.Config{})
	if err != nil {
		return err
	}
	defer setup.close()
	return runTUI(ctx, setup, options, input, output, radio.Run)
}

func runTUI(ctx context.Context, setup *playbackSetup, options listenOptions, input io.Reader, output io.Writer, run controllerRunner, extra ...tea.ProgramOption) (result error) {
	session := startTUISession(ctx, setup.cfg, run)
	defer func() {
		err := session.close()
		if err != nil && !errors.Is(result, err) {
			result = errors.Join(result, err)
		}
	}()
	selected := setup.selected["id"].(string)
	for _, command := range []struct {
		action string
		fields map[string]any
	}{
		{"configure", map[string]any{"stationId": selected}},
		{"volume", map[string]any{"value": options.volume}},
		{"mute", map[string]any{"value": options.muted}},
		{"play", nil},
	} {
		if _, err := session.send(command.action, command.fields); err != nil {
			return err
		}
	}
	model := newTUIModel(setup.stations, selected, options, session.send, session.states)
	programOptions := []tea.ProgramOption{tea.WithContext(ctx), tea.WithInput(input), tea.WithOutput(output), tea.WithoutSignalHandler()}
	programOptions = append(programOptions, extra...)
	final, err := tea.NewProgram(model, programOptions...).Run()
	if ctx.Err() != nil && (errors.Is(err, tea.ErrProgramKilled) || errors.Is(err, context.Canceled)) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("terminal interface: %w", err)
	}
	if finalModel, ok := final.(tuiModel); ok {
		return finalModel.fatal
	}
	return nil
}
