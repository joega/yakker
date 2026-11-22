package recording

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// captureBitrate applies to new recordings only.
const captureBitrate = "24k"
const defaultStopGrace = 5 * time.Second

var errCaptureStopTimeout = errors.New("capture: encoder did not stop gracefully")

type CaptureOptions struct {
	FFmpeg, FFprobe, URL, Path string
	End                        time.Time
	StopGrace                  time.Duration
}
type CaptureResult struct {
	Bytes           int64
	DurationSeconds float64
	// Encoder lifetime, separate from the later probe/finalization work. These
	// are local process times, not timestamps of the broadcaster's programme.
	StartedAt, EndedAt time.Time
	Err                error
}
type Capture struct {
	stop      chan struct{}
	finished  chan struct{}
	done      chan CaptureResult
	once      sync.Once
	pid       int
	startedAt time.Time
}

// StartCapture starts a single encoder writing an exclusively created Ogg file.
func StartCapture(ctx context.Context, options CaptureOptions) (*Capture, error) {
	if ctx == nil {
		return nil, errors.New("capture: nil context")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if options.URL == "" || options.Path == "" {
		return nil, errors.New("capture: URL and output path are required")
	}
	if !options.End.IsZero() && !time.Now().Before(options.End) {
		return nil, errors.New("capture: scheduled end has already passed")
	}
	if options.FFmpeg == "" {
		options.FFmpeg = "ffmpeg"
	}
	if options.FFprobe == "" {
		options.FFprobe = "ffprobe"
	}
	if options.StopGrace <= 0 {
		options.StopGrace = defaultStopGrace
	}
	f, err := os.OpenFile(options.Path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return nil, fmt.Errorf("capture: create output: %w", err)
	}
	cmd := exec.Command(options.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-rw_timeout", "15000000", "-i", options.URL, "-map", "0:a:0", "-vn", "-ac", "1", "-c:a", "libopus", "-b:a", captureBitrate, "-vbr", "on", "-f", "ogg", "pipe:3")
	cmd.ExtraFiles = []*os.File{f}
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	// Diagnostics may contain credential-bearing input URLs. Drain and discard them.
	cmd.Stderr = io.Discard
	c := &Capture{stop: make(chan struct{}), finished: make(chan struct{}), done: make(chan CaptureResult, 1)}
	started := make(chan error, 1)
	// Linux Pdeathsig tracks the creating thread, so keep that OS thread alive
	// until the child has been reaped, even if the caller's goroutine moves.
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		if err := cmd.Start(); err != nil {
			_ = f.Close()
			_ = os.Remove(options.Path)
			started <- fmt.Errorf("capture: start encoder: %w", err)
			return
		}
		_ = f.Close()
		c.pid = cmd.Process.Pid
		c.startedAt = time.Now()
		started <- nil
		c.run(ctx, cmd, options)
	}()
	if err := <-started; err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Capture) Done() <-chan CaptureResult { return c.done }
func (c *Capture) Stop()                      { c.once.Do(func() { close(c.stop) }); <-c.finished }

func (c *Capture) run(ctx context.Context, cmd *exec.Cmd, options CaptureOptions) {
	defer close(c.finished)
	defer close(c.done)
	type exitResult struct {
		err error
		at  time.Time
	}
	exited := make(chan exitResult, 1)
	go func() {
		err := cmd.Wait()
		exited <- exitResult{err: err, at: time.Now()}
	}()
	var timer *time.Timer
	var end <-chan time.Time
	if !options.End.IsZero() {
		delay := time.Until(options.End)
		if delay < 0 {
			delay = 0
		}
		timer = time.NewTimer(delay)
		end = timer.C
		defer timer.Stop()
	}
	var exit exitResult
	var reason error
	stopped := false
	select {
	case exit = <-exited:
	case <-c.stop:
		stopped = true
	case <-end:
		stopped = true
	case <-ctx.Done():
		stopped = true
		reason = ctx.Err()
	}
	if stopped {
		_ = cmd.Process.Signal(os.Interrupt)
		grace := time.NewTimer(options.StopGrace)
		select {
		case exit = <-exited:
			if !grace.Stop() {
				<-grace.C
			}
		case <-grace.C:
			_ = cmd.Process.Kill()
			exit = <-exited
			if reason == nil {
				reason = errCaptureStopTimeout
			}
		}
	}
	probeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	result, probeErr := ProbeRecording(probeCtx, options.FFprobe, options.Path)
	cancel()
	result.StartedAt, result.EndedAt = c.startedAt, exit.at
	if info, err := os.Stat(options.Path); err == nil {
		result.Bytes = info.Size()
	}
	if reason != nil {
		result.Err = reason
	} else if probeErr != nil {
		result.Err = probeErr
	} else if exit.err != nil && !stopped {
		result.Err = errors.New("capture: encoder exited unsuccessfully")
	}
	c.done <- result
}

// ProbeRecording validates a nonempty mono Opus file and obtains its duration.
func ProbeRecording(ctx context.Context, ffprobe, path string) (CaptureResult, error) {
	var result CaptureResult
	info, err := os.Stat(path)
	if err != nil {
		return result, fmt.Errorf("probe recording: %w", err)
	}
	result.Bytes = info.Size()
	if !info.Mode().IsRegular() || result.Bytes <= 0 {
		return result, errors.New("probe recording: output is empty or not a regular file")
	}
	if ffprobe == "" {
		ffprobe = "ffprobe"
	}
	cmd := exec.CommandContext(ctx, ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name,channels:format=duration,format_name", "-of", "json", path)
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
	var output limitedBuffer
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := cmd.Run(); err != nil {
		return result, errors.New("probe recording: ffprobe failed")
	}
	if output.overflow {
		return result, errors.New("probe recording: excessive probe output")
	}
	var data struct {
		Streams []struct {
			Codec    string `json:"codec_name"`
			Channels int    `json:"channels"`
		} `json:"streams"`
		Format struct {
			Duration string `json:"duration"`
			Name     string `json:"format_name"`
		} `json:"format"`
	}
	if json.Unmarshal(output.Bytes(), &data) != nil || len(data.Streams) != 1 || data.Streams[0].Codec != "opus" || data.Streams[0].Channels != 1 || data.Format.Name != "ogg" {
		return result, errors.New("probe recording: expected mono Ogg Opus audio")
	}
	duration, err := strconv.ParseFloat(data.Format.Duration, 64)
	if err != nil || math.IsNaN(duration) || math.IsInf(duration, 0) || duration <= 0 {
		return result, errors.New("probe recording: invalid duration")
	}
	result.DurationSeconds = duration
	return result, nil
}

type limitedBuffer struct {
	bytes.Buffer
	overflow bool
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	const limit = 64 << 10
	if b.Len()+n > limit {
		b.overflow = true
		remaining := limit - b.Len()
		if remaining > 0 {
			_, _ = b.Buffer.Write(p[:remaining])
		}
		return n, nil
	}
	_, _ = b.Buffer.Write(p)
	return n, nil
}
