package recording

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A paced, effectively unbounded PCM stream resembles a live radio source.
func liveWAV(t *testing.T, stallAfter ...time.Duration) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "audio/wav")
		h := make([]byte, 44)
		copy(h, "RIFF")
		binary.LittleEndian.PutUint32(h[4:], 0x7fffffff)
		copy(h[8:], "WAVEfmt ")
		binary.LittleEndian.PutUint32(h[16:], 16)
		binary.LittleEndian.PutUint16(h[20:], 1)
		binary.LittleEndian.PutUint16(h[22:], 1)
		binary.LittleEndian.PutUint32(h[24:], 48000)
		binary.LittleEndian.PutUint32(h[28:], 96000)
		binary.LittleEndian.PutUint16(h[32:], 2)
		binary.LittleEndian.PutUint16(h[34:], 16)
		copy(h[36:], "data")
		binary.LittleEndian.PutUint32(h[40:], 0x7fffffdb)
		_, _ = w.Write(h)
		flusher := w.(http.Flusher)
		flusher.Flush()
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		sample := 0
		for {
			if len(stallAfter) > 0 && time.Duration(sample)*time.Second/48000 >= stallAfter[0] {
				<-r.Context().Done()
				return
			}
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				block := make([]byte, 1920)
				for i := 0; i < 960; i++ {
					v := int16(12000 * math.Sin(2*math.Pi*440*float64(sample)/48000))
					binary.LittleEndian.PutUint16(block[i*2:], uint16(v))
					sample++
				}
				if _, err := w.Write(block); err != nil {
					return
				}
				flusher.Flush()
			}
		}
	}))
	t.Cleanup(server.Close)
	return server.URL
}
func mediaTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"ffmpeg", "ffprobe", "mpv"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s unavailable", tool)
		}
	}
}
func receive(t *testing.T, c *Capture) CaptureResult {
	t.Helper()
	select {
	case r, ok := <-c.Done():
		if !ok {
			t.Fatal("missing capture result")
		}
		if _, ok = <-c.Done(); ok {
			t.Fatal("multiple results")
		}
		for _, pid := range []int{c.pid, c.readerPID} {
			if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
				t.Fatalf("capture process %d still exists after completion: %v", pid, err)
			}
		}
		return r
	case <-time.After(15 * time.Second):
		t.Fatal("capture did not finish")
		return CaptureResult{}
	}
}
func verifyPlayback(t *testing.T, path string, r CaptureResult) {
	t.Helper()
	if r.Err != nil || r.Bytes <= 0 || r.DurationSeconds <= 0 {
		t.Fatalf("invalid result: %+v", r)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if out, err := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-i", path, "-f", "null", "-").CombinedOutput(); err != nil {
		t.Fatalf("decode: %v: %s", err, out)
	}
	out, err := exec.CommandContext(ctx, "mpv", "--no-config", "--load-scripts=no", "--no-video", "--ao=null", "--start="+fmt.Sprint(r.DurationSeconds/2), "--length=0.2", path).CombinedOutput()
	if err != nil {
		t.Fatalf("mid-file playback: %v: %s", err, out)
	}
}
func TestCaptureScheduledAndManual(t *testing.T) {
	mediaTools(t)
	url := liveWAV(t)
	for _, scheduled := range []bool{true, false} {
		t.Run(fmt.Sprint(scheduled), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "capture.opus.partial")
			opts := CaptureOptions{URL: url, Path: path, StopGrace: 3 * time.Second}
			if scheduled {
				opts.End = time.Now().Add(3 * time.Second)
			}
			c, err := StartCapture(context.Background(), opts)
			if err != nil {
				t.Fatal(err)
			}
			if !scheduled {
				time.Sleep(3 * time.Second)
				c.Stop()
				c.Stop()
			}
			result := receive(t, c)
			verifyPlayback(t, path, result)
			if result.DurationSeconds < 0.5 {
				t.Fatalf("unexpected duration: %+v", result)
			}
		})
	}
}
func TestCaptureCancellationAndFailures(t *testing.T) {
	mediaTools(t)
	url := liveWAV(t)
	t.Run("cancel retains audio", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "cancel.partial")
		ctx, cancel := context.WithCancel(context.Background())
		c, err := StartCapture(ctx, CaptureOptions{URL: url, Path: path, StopGrace: 3 * time.Second})
		if err != nil {
			t.Fatal(err)
		}
		time.Sleep(3 * time.Second)
		cancel()
		r := receive(t, c)
		if !errors.Is(r.Err, context.Canceled) {
			t.Fatalf("expected canceled: %+v", r)
		}
		r.Err = nil
		verifyPlayback(t, path, r)
	})
	t.Run("missing encoder", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "missing.partial")
		_, err := StartCapture(context.Background(), CaptureOptions{FFmpeg: "/missing/ffmpeg", URL: url, Path: path})
		if err == nil {
			t.Fatal("expected error")
		}
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("empty artifact remains: %v", err)
		}
	})
	t.Run("probe failure", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "probe.partial")
		c, err := StartCapture(context.Background(), CaptureOptions{FFprobe: "/missing/ffprobe", URL: url, Path: path, End: time.Now().Add(3 * time.Second)})
		if err != nil {
			t.Fatal(err)
		}
		r := receive(t, c)
		if r.Err == nil || r.Bytes == 0 {
			t.Fatalf("expected probe failure with bytes: %+v", r)
		}
		valid, err := ProbeRecording(context.Background(), "ffprobe", path)
		if err != nil {
			t.Fatal(err)
		}
		verifyPlayback(t, path, valid)
	})
	t.Run("no overwrite", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "exists.partial")
		if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
			t.Fatal(err)
		}
		_, err := StartCapture(context.Background(), CaptureOptions{URL: url, Path: path})
		if err == nil {
			t.Fatal("expected create failure")
		}
		b, _ := os.ReadFile(path)
		if string(b) != "original" {
			t.Fatal("overwrote existing file")
		}
	})
	t.Run("failed source does not expose URL", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "bad.partial")
		secret := "secret-credential"
		c, err := StartCapture(context.Background(), CaptureOptions{URL: "http://127.0.0.1:1/" + secret, Path: path})
		if err != nil {
			t.Fatal(err)
		}
		r := receive(t, c)
		if r.Err == nil || strings.Contains(r.Err.Error(), secret) {
			t.Fatalf("bad error: %v", r.Err)
		}
	})
}

func TestCaptureRejectsExpiredWindowWithoutCreatingOutput(t *testing.T) {
	path := filepath.Join(t.TempDir(), "expired.partial")
	_, err := StartCapture(context.Background(), CaptureOptions{URL: "http://127.0.0.1:1", Path: path, End: time.Now().Add(-time.Second)})
	if err == nil {
		t.Fatal("expired capture window launched an encoder")
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expired capture created an artifact: %v", err)
	}
}

func TestCaptureTimestampsExcludeProbeDelay(t *testing.T) {
	mediaTools(t)
	dir := t.TempDir()
	clip := filepath.Join(dir, "source.opus")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.25", "-ac", "1", "-c:a", "libopus", clip).CombinedOutput(); err != nil {
		t.Fatalf("fixture audio: %v: %s", err, out)
	}
	probe, err := exec.LookPath("ffprobe")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("YAKKER_CAPTURE_TEST_PROBE", probe)
	probeWrapper := filepath.Join(dir, "probe")
	if err := os.WriteFile(probeWrapper, []byte("#!/bin/sh\nsleep 0.5\nexec \"$YAKKER_CAPTURE_TEST_PROBE\" \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	before := time.Now()
	capture, err := StartCapture(context.Background(), CaptureOptions{FFprobe: probeWrapper, URL: clip, Path: filepath.Join(dir, "capture.partial")})
	if err != nil {
		t.Fatal(err)
	}
	result := receive(t, capture)
	if result.Err != nil {
		t.Fatal(result.Err)
	}
	if result.StartedAt.Before(before) || result.EndedAt.Before(result.StartedAt) {
		t.Fatalf("invalid encoder timestamps: %+v", result)
	}
	if time.Since(result.EndedAt) < 450*time.Millisecond {
		t.Fatalf("probe delay changed capture end: %+v", result)
	}
}

func TestCaptureEscalatesAndReaps(t *testing.T) {
	dir := t.TempDir()
	encoder := filepath.Join(dir, "stubborn")
	if err := os.WriteFile(encoder, []byte("#!/bin/sh\ntrap '' INT\nexec sleep 30\n"), 0700); err != nil {
		t.Fatal(err)
	}
	c, err := StartCapture(context.Background(), CaptureOptions{FFmpeg: encoder, URL: "test", Path: filepath.Join(dir, "out.partial"), StopGrace: 100 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	start := time.Now()
	c.Stop()
	if time.Since(start) > 3*time.Second {
		t.Fatal("stop exceeded bound")
	}
	r := receive(t, c)
	if r.Err == nil || !strings.Contains(r.Err.Error(), "gracefully") {
		t.Fatalf("expected escalation error: %+v", r)
	}
}

func TestAbruptEncoderLossRetainsPlayablePartial(t *testing.T) {
	mediaTools(t)
	path := filepath.Join(t.TempDir(), "interrupted.partial")
	c, err := StartCapture(context.Background(), CaptureOptions{URL: liveWAV(t), Path: path})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(8 * time.Second)
	if err := syscall.Kill(c.pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	r := receive(t, c)
	if r.Err == nil {
		t.Fatal("expected encoder failure")
	}
	r.Err = nil
	verifyPlayback(t, path, r)
}

func TestCaptureDeadlineFlushesStalledInput(t *testing.T) {
	mediaTools(t)
	end := time.Now().Add(4 * time.Second)
	path := filepath.Join(t.TempDir(), "stalled.partial")
	capture, err := StartCapture(context.Background(), CaptureOptions{URL: liveWAV(t, 3*time.Second), Path: path, End: end, StopGrace: 1500 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	result := receive(t, capture)
	verifyPlayback(t, path, result)
	if result.EndedAt.After(end.Add(time.Second)) {
		t.Fatalf("stalled input exceeded stop deadline: %s", result.EndedAt.Sub(end))
	}
	if result.DurationSeconds < 2.8 || result.DurationSeconds > 3.1 {
		t.Fatalf("stalled input was not flushed: %+v", result)
	}
}

func TestReaderCrashStillFinalizesReceivedAudio(t *testing.T) {
	mediaTools(t)
	path := filepath.Join(t.TempDir(), "reader-crash.partial")
	capture, err := StartCapture(context.Background(), CaptureOptions{URL: liveWAV(t), Path: path, StopGrace: 2 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	// Wait for encoded audio, not just the Ogg headers. Killing a reader during
	// its initial input probe can legitimately leave no decoded PCM to recover.
	deadline := time.Now().Add(10 * time.Second)
	for {
		info, err := os.Stat(path)
		if err == nil && info.Size() > 512 {
			break
		}
		if time.Now().After(deadline) {
			capture.Stop()
			t.Fatal("reader never delivered audio")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err := syscall.Kill(capture.readerPID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	result := receive(t, capture)
	if result.Err == nil {
		t.Fatal("reader crash reported success")
	}
	assertOggEOS(t, path)
	result.Err = nil
	verifyPlayback(t, path, result)
}

func TestReaderCrashBeforeAudioReportsNoRecoverableDuration(t *testing.T) {
	mediaTools(t)
	requested := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case requested <- struct{}{}:
		default:
		}
		<-r.Context().Done()
	}))
	defer server.Close()
	capture, err := StartCapture(context.Background(), CaptureOptions{URL: server.URL, Path: filepath.Join(t.TempDir(), "no-audio.partial"), StopGrace: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-requested:
	case <-time.After(3 * time.Second):
		capture.Stop()
		t.Fatal("source request did not arrive")
	}
	if err := syscall.Kill(capture.readerPID, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	result := receive(t, capture)
	if result.Err == nil || result.DurationSeconds != 0 {
		t.Fatalf("empty crash invented recoverable audio: %+v", result)
	}
}

// HLS may block while reloading an unchanged live playlist. A bounded hard
// stop must drain the independent encoder and retain the received ending audio.
func TestCaptureStalledHLSDrainsTailWithinStopBound(t *testing.T) {
	mediaTools(t)
	dir := t.TempDir()
	playlist := filepath.Join(dir, "stream.m3u8")
	if out, err := exec.Command("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=5.9", "-c:a", "aac", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0", "-hls_flags", "omit_endlist", playlist).CombinedOutput(); err != nil {
		t.Fatalf("HLS fixture: %v: %s", err, out)
	}
	server := httptest.NewServer(http.FileServer(http.Dir(dir)))
	defer server.Close()
	end := time.Now().Add(2800 * time.Millisecond)
	path := filepath.Join(t.TempDir(), "stalled-hls.partial")
	capture, err := StartCapture(context.Background(), CaptureOptions{URL: server.URL + "/stream.m3u8", Path: path, End: end, StopGrace: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	result := receive(t, capture)
	if result.EndedAt.After(end.Add(1500 * time.Millisecond)) {
		t.Fatalf("HLS stop exceeded bound: %s", result.EndedAt.Sub(end))
	}
	if !errors.Is(result.Err, errCaptureReaderTimeout) {
		t.Fatalf("stalled reader was not identified: %+v", result)
	}
	if result.DurationSeconds < 5.85 || result.DurationSeconds > 6.1 {
		t.Fatalf("received HLS tail was lost: %+v", result)
	}
	assertOggEOS(t, path)
	// Interrupted audio remains usable; the manager must keep its partial status.
	result.Err = nil
	verifyPlayback(t, path, result)
}

// A complete final page distinguishes a drained file from playable crash output.
func assertOggEOS(t *testing.T, path string) {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var flags byte
	for len(data) > 0 {
		if len(data) < 27 || string(data[:4]) != "OggS" {
			t.Fatal("invalid Ogg page")
		}
		n := int(data[26])
		if len(data) < 27+n {
			t.Fatal("incomplete Ogg header")
		}
		size := 27 + n
		for _, length := range data[27 : 27+n] {
			size += int(length)
		}
		if size > len(data) {
			t.Fatal("incomplete Ogg page")
		}
		flags = data[5]
		data = data[size:]
	}
	if flags&4 == 0 {
		t.Fatal("recording lacks a finalized EOS page")
	}
}
