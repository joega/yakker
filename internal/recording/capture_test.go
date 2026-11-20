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
func liveWAV(t *testing.T) string {
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
		if err := syscall.Kill(c.pid, 0); !errors.Is(err, syscall.ESRCH) {
			t.Fatalf("encoder process still exists after completion: %v", err)
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
	out, err := exec.CommandContext(ctx, "mpv", "--no-config", "--no-video", "--ao=null", "--start="+fmt.Sprint(r.DurationSeconds/2), "--length=0.2", path).CombinedOutput()
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
