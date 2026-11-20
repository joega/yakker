package tool

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"

	"github.com/joega/yakker/internal/radio"
)

// tuiSession serializes commands before writing them to the controller. Bubble
// Tea can schedule commands concurrently; player controls must retain key order.
type tuiSession struct {
	ctx                                context.Context
	cancel                             context.CancelFunc
	input                              *io.PipeWriter
	output                             *io.PipeReader
	commands                           chan map[string]any
	states                             chan statusEvent
	engineDone, writerDone, readerDone chan struct{}
	mu                                 sync.Mutex
	serial                             int64
	engineErr, writerErr, result       error
	once                               sync.Once
}

func startTUISession(parent context.Context, cfg radio.Config, run controllerRunner) *tuiSession {
	ctx, cancel := context.WithCancel(parent)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &tuiSession{ctx: ctx, cancel: cancel, input: inW, output: outR, commands: make(chan map[string]any, 64), states: make(chan statusEvent, 64), engineDone: make(chan struct{}), writerDone: make(chan struct{}), readerDone: make(chan struct{})}
	go func() {
		// mpv's last diagnostic is already included in controller error status. Raw
		// stderr must not print over the full-screen interface.
		s.engineErr = run(ctx, cfg, inR, outW, io.Discard)
		_ = inR.CloseWithError(s.engineErr)
		_ = outW.CloseWithError(s.engineErr)
		close(s.engineDone)
	}()
	go func() {
		defer close(s.writerDone)
		encoder := json.NewEncoder(inW)
		for {
			select {
			case <-ctx.Done():
				return
			case command := <-s.commands:
				if err := encoder.Encode(command); err != nil {
					s.writerErr = err
					return
				}
			}
		}
	}()
	go func() {
		defer close(s.readerDone)
		defer close(s.states)
		scanner := bufio.NewScanner(outR)
		scanner.Buffer(make([]byte, 4096), 16*1024*1024)
		for scanner.Scan() {
			var status radio.Status
			err := json.Unmarshal(scanner.Bytes(), &status)
			select {
			case s.states <- statusEvent{status: status, err: err}:
			case <-ctx.Done():
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
			case s.states <- statusEvent{err: err}:
			case <-ctx.Done():
			}
		}
	}()
	return s
}

func (s *tuiSession) send(action string, fields map[string]any) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ctx.Err() != nil {
		return 0, s.ctx.Err()
	}
	command := make(map[string]any, len(fields)+2)
	for key, value := range fields {
		command[key] = value
	}
	next := s.serial + 1
	command["action"] = action
	command["serial"] = next
	select {
	case s.commands <- command:
		s.serial = next
		return next, nil
	default:
		return 0, errors.New("controls are busy; try again in a moment")
	}
}

func (s *tuiSession) close() error {
	s.once.Do(func() {
		s.cancel()
		_ = s.input.Close()
		<-s.engineDone
		<-s.writerDone
		<-s.readerDone
		_ = s.output.Close()
		s.result = s.engineErr
		if s.writerErr != nil && !errors.Is(s.writerErr, io.ErrClosedPipe) && !errors.Is(s.result, s.writerErr) {
			s.result = errors.Join(s.result, s.writerErr)
		}
	})
	return s.result
}
