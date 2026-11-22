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
var errCaptureReaderTimeout = errors.New("capture: stream reader did not stop gracefully")
var errCaptureEncoderFailed = errors.New("capture: encoder exited unsuccessfully")

type CaptureOptions struct {
	FFmpeg, FFprobe, URL, Path string
	End                        time.Time
	StopGrace                  time.Duration
}
type CaptureResult struct {
	Bytes           int64
	DurationSeconds float64
	// Stream-reader lifetime, excluding encoder drain and later probing. These
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
	readerPID int
	startedAt time.Time
}

// StartCapture starts a reader and writer with an exclusively created Ogg file.
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
	readPipe, writePipe, err := os.Pipe()
	if err != nil {
		_ = f.Close()
		_ = os.Remove(options.Path)
		return nil, fmt.Errorf("capture: create audio pipe: %w", err)
	}
	// The source reader can stall inside a demuxer (notably HLS reloads).
	// Give the writer independent EOF so it can drain Opus and write its trailer
	// even when the reader must be killed. Float PCM avoids an intermediate
	// lossy encode or integer clipping; the pipe bounds in-memory audio.
	reader := exec.Command(options.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-rw_timeout", "15000000", "-i", options.URL, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", "-flush_packets", "1", "-f", "f32le", "pipe:1")
	reader.Stdout = writePipe
	cmd := exec.Command(options.FFmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", "pipe:0", "-c:a", "libopus", "-b:a", captureBitrate, "-vbr", "on", "-page_duration", "200000", "-flush_packets", "1", "-f", "ogg", "pipe:3")
	cmd.Stdin = readPipe
	cmd.ExtraFiles = []*os.File{f}
	for _, process := range []*exec.Cmd{reader, cmd} {
		process.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
		// Diagnostics may contain credential-bearing input URLs.
		process.Stderr = io.Discard
	}
	c := &Capture{stop: make(chan struct{}), finished: make(chan struct{}), done: make(chan CaptureResult, 1)}
	started := make(chan error, 1)
	// Linux Pdeathsig tracks the creating thread. Keep it alive until both
	// children have been reaped, even if the caller's goroutine moves.
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		closeFiles := func() { _ = f.Close(); _ = readPipe.Close(); _ = writePipe.Close() }
		if err := cmd.Start(); err != nil {
			closeFiles()
			_ = os.Remove(options.Path)
			started <- fmt.Errorf("capture: start encoder: %w", err)
			return
		}
		if err := reader.Start(); err != nil {
			closeFiles()
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
			_ = os.Remove(options.Path)
			started <- fmt.Errorf("capture: start stream reader: %w", err)
			return
		}
		closeFiles()
		c.pid, c.readerPID = cmd.Process.Pid, reader.Process.Pid
		c.startedAt = time.Now()
		started <- nil
		c.run(ctx, reader, cmd, options)
	}()
	if err := <-started; err != nil {
		return nil, err
	}
	return c, nil
}

func (c *Capture) Done() <-chan CaptureResult { return c.done }
func (c *Capture) Stop()                      { c.once.Do(func() { close(c.stop) }); <-c.finished }

type captureExit struct {
	err error
	at  time.Time
}

func watchCaptureProcess(cmd *exec.Cmd) <-chan captureExit {
	done := make(chan captureExit, 1)
	go func() { err := cmd.Wait(); done <- captureExit{err: err, at: time.Now()} }()
	return done
}

// waitCaptureProcess always reaps its child and reports forced termination.
func waitCaptureProcess(cmd *exec.Cmd, done <-chan captureExit, grace time.Duration) (captureExit, bool) {
	select {
	case exit := <-done:
		return exit, false
	default:
	}
	timer := time.NewTimer(max(0, grace))
	defer timer.Stop()
	select {
	case exit := <-done:
		return exit, false
	case <-timer.C:
		_ = cmd.Process.Kill()
		return <-done, true
	}
}

func (c *Capture) run(ctx context.Context, reader, cmd *exec.Cmd, options CaptureOptions) {
	defer close(c.finished)
	defer close(c.done)
	readerDone, encoderDone := watchCaptureProcess(reader), watchCaptureProcess(cmd)
	var timer *time.Timer
	var end <-chan time.Time
	if !options.End.IsZero() {
		timer = time.NewTimer(max(0, time.Until(options.End)))
		end = timer.C
		defer timer.Stop()
	}
	var inputExit, outputExit captureExit
	var inputFinished, outputFinished, stopped bool
	var reason error
	select {
	case inputExit = <-readerDone:
		inputFinished = true
	case outputExit = <-encoderDone:
		outputFinished = true
	case <-c.stop:
		stopped = true
	case <-end:
		stopped = true
	case <-ctx.Done():
		stopped = true
		reason = ctx.Err()
	}
	// One total stop budget, reserving its last third for the independent
	// encoder to consume buffered PCM, close the final page and write EOS.
	deadline := time.Now().Add(options.StopGrace)
	if !inputFinished {
		_ = reader.Process.Signal(os.Interrupt)
		var killed bool
		inputExit, killed = waitCaptureProcess(reader, readerDone, options.StopGrace*2/3)
		if killed {
			reason = errors.Join(reason, errCaptureReaderTimeout)
		}
	}
	if !outputFinished {
		var killed bool
		outputExit, killed = waitCaptureProcess(cmd, encoderDone, time.Until(deadline))
		if killed {
			reason = errors.Join(reason, errCaptureStopTimeout)
		}
	}
	if outputExit.err != nil && !errors.Is(reason, errCaptureStopTimeout) {
		reason = errors.Join(reason, errCaptureEncoderFailed)
	}
	if inputExit.err != nil && !stopped && reason == nil {
		reason = errors.New("capture: stream reader exited unsuccessfully")
	}
	probeCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	result, probeErr := ProbeRecording(probeCtx, options.FFprobe, options.Path)
	cancel()
	result.StartedAt, result.EndedAt = c.startedAt, inputExit.at
	if info, err := os.Stat(options.Path); err == nil {
		result.Bytes = info.Size()
	}
	if reason != nil {
		result.Err = reason
	} else if probeErr != nil {
		result.Err = probeErr
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
