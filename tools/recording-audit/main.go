// recording-audit measures capture timing without using the installed controller.
package main

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/joega/yakker/internal/recording"
)

const sampleRate = 16000

type measurement struct {
	CaptureStartedAt   string  `json:"captureStartedAt,omitempty"`
	CaptureEndedAt     string  `json:"captureEndedAt,omitempty"`
	Status             string  `json:"status,omitempty"`
	Source             string  `json:"source"`
	WindowSeconds      float64 `json:"windowSeconds"`
	FinishedSeconds    float64 `json:"finishedSeconds"`
	ReportedSeconds    float64 `json:"reportedSeconds"`
	DecodedSeconds     float64 `json:"decodedSeconds"`
	RequestSeconds     float64 `json:"requestSeconds,omitempty"`
	FirstWrite         float64 `json:"firstWriteSeconds,omitempty"`
	FirstSource        float64 `json:"firstSourceSecond,omitempty"`
	LastSource         float64 `json:"lastSourceSecond,omitempty"`
	SourceSamples      int     `json:"sourceSamplesDelivered,omitempty"`
	RMSDB              float64 `json:"rmsDB"`
	PeakDB             float64 `json:"peakDB"`
	ClippedSamples     int     `json:"clippedSamples"`
	Bytes              int64   `json:"bytes"`
	ProgramStartSecond float64 `json:"programStartSecond,omitempty"`
	ProgramEndSecond   float64 `json:"programEndSecond,omitempty"`
	Error              string  `json:"error,omitempty"`
	DecodeError        string  `json:"decodeError,omitempty"`
}

type fixture struct {
	mu      sync.Mutex
	request time.Time
	samples int
}

// An 8-second burst models the initial buffered audio sent by some live feeds.
// The chirp's frequency identifies its original position after lossy encoding.
func source(burst int, delay time.Duration, origin ...time.Time) (*httptest.Server, *fixture) {
	f := &fixture{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.request = time.Now()
		f.mu.Unlock()
		select {
		case <-time.After(delay):
		case <-r.Context().Done():
			return
		}
		w.Header().Set("Content-Type", "audio/wav")
		h := make([]byte, 44)
		copy(h, "RIFF")
		binary.LittleEndian.PutUint32(h[4:], 0x7fffffff)
		copy(h[8:], "WAVEfmt ")
		binary.LittleEndian.PutUint32(h[16:], 16)
		binary.LittleEndian.PutUint16(h[20:], 1)
		binary.LittleEndian.PutUint16(h[22:], 1)
		binary.LittleEndian.PutUint32(h[24:], sampleRate)
		binary.LittleEndian.PutUint32(h[28:], sampleRate*2)
		binary.LittleEndian.PutUint16(h[32:], 2)
		binary.LittleEndian.PutUint16(h[34:], 16)
		copy(h[36:], "data")
		binary.LittleEndian.PutUint32(h[40:], 0x7fffffdb)
		_, _ = w.Write(h)
		flush := w.(http.Flusher)
		flush.Flush()
		sample := 0
		if len(origin) > 0 {
			sample = int(time.Since(origin[0]).Seconds() * sampleRate)
		}
		firstSample := sample
		write := func(count int) bool {
			data := make([]byte, count*2)
			for i := 0; i < count; i++ {
				t := float64(sample+i) / sampleRate
				value := int16(14000 * math.Sin(2*math.Pi*(300*t+15*t*t)))
				binary.LittleEndian.PutUint16(data[i*2:], uint16(value))
			}
			if _, err := w.Write(data); err != nil {
				return false
			}
			flush.Flush()
			sample += count
			f.mu.Lock()
			f.samples = sample - firstSample
			f.mu.Unlock()
			return true
		}
		if burst > 0 && !write(burst*sampleRate) {
			return
		}
		ticker := time.NewTicker(20 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				if !write(sampleRate / 50) {
					return
				}
			}
		}
	}))
	return server, f
}

func chirpPosition(samples []float64, tail bool) float64 {
	if len(samples) < sampleRate/2 {
		return 0
	}
	start, end := sampleRate/25, sampleRate/4
	if tail {
		start, end = len(samples)-sampleRate/4, len(samples)-sampleRate/25
	}
	var crossings []float64
	for i := start + 1; i < end; i++ {
		if samples[i-1] <= 0 && samples[i] > 0 {
			crossings = append(crossings, float64(i)-samples[i]/(samples[i]-samples[i-1]))
		}
	}
	if len(crossings) < 3 {
		return 0
	}
	a, b := crossings[0], crossings[len(crossings)-1]
	freq := float64(len(crossings)-1) * sampleRate / (b - a)
	mid := (a + b) / 2 / sampleRate
	position := (freq - 300) / 30
	if tail {
		return position + float64(len(samples))/sampleRate - mid
	}
	return position - mid
}

func audit(id, url, output string, duration time.Duration, f *fixture) measurement {
	r := measurement{Source: id, WindowSeconds: duration.Seconds()}
	path := filepath.Join(output, id+".opus")
	start := time.Now()
	capture, err := recording.StartCapture(context.Background(), recording.CaptureOptions{URL: url, Path: path, End: start.Add(duration)})
	if err != nil {
		r.Error = err.Error()
		return r
	}
	result := capture.Done()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	var captured recording.CaptureResult
wait:
	for {
		select {
		case captured = <-result:
			break wait
		case <-ticker.C:
			if r.FirstWrite == 0 {
				if stat, err := os.Stat(path); err == nil && stat.Size() > 0 {
					r.FirstWrite = time.Since(start).Seconds()
				}
			}
		}
	}
	r.FinishedSeconds, r.ReportedSeconds, r.Bytes = time.Since(start).Seconds(), captured.DurationSeconds, captured.Bytes
	if !captured.StartedAt.IsZero() {
		r.CaptureStartedAt = captured.StartedAt.Format(time.RFC3339Nano)
		r.CaptureEndedAt = captured.EndedAt.Format(time.RFC3339Nano)
	}
	if captured.Err != nil {
		r.Error = captured.Err.Error()
	}
	return analyzeAudio(r, path, f, start)
}

func analyzeAudio(r measurement, path string, f *fixture, start time.Time) measurement {
	if f != nil {
		f.mu.Lock()
		r.RequestSeconds, r.SourceSamples = f.request.Sub(start).Seconds(), f.samples
		f.mu.Unlock()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pcm, err := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", fmt.Sprint(sampleRate), "-f", "s16le", "pipe:1").Output()
	if err != nil {
		r.DecodeError = "audio could not be decoded"
		return r
	}
	samples := make([]float64, len(pcm)/2)
	var sum, peak float64
	for i := range samples {
		x := float64(int16(binary.LittleEndian.Uint16(pcm[i*2:]))) / 32768
		samples[i] = x
		sum += x * x
		peak = math.Max(peak, math.Abs(x))
		if math.Abs(x) >= 0.9999 {
			r.ClippedSamples++
		}
	}
	r.DecodedSeconds = float64(len(samples)) / sampleRate
	r.RMSDB = 10 * math.Log10(math.Max(1e-20, sum/math.Max(1, float64(len(samples)))))
	r.PeakDB = 20 * math.Log10(math.Max(1e-10, peak))
	if f != nil {
		r.FirstSource, r.LastSource = chirpPosition(samples, false), chirpPosition(samples, true)
	}
	return r
}

// scheduledAudit exercises the actual one-minute rule and default scheduler
// poll, with a source whose chirp position is tied to the planned wall clock.
func scheduledAudit(output string, padding time.Duration) measurement {
	start := time.Now().UTC().Add(padding + 2*time.Second).Truncate(time.Minute).Add(time.Minute)
	end := start.Add(time.Minute)
	captureStart, captureEnd := start.Add(-padding), end.Add(padding)
	fmt.Printf("Scheduled boundary audit: %s to %s\n", start.Format(time.RFC3339), end.Format(time.RFC3339))
	fmt.Printf("Capture window: %s to %s\n", captureStart.Format(time.RFC3339), captureEnd.Format(time.RFC3339))
	server, fixture := source(0, 0, captureStart)
	defer server.Close()
	root, err := filepath.Abs(output)
	if err != nil {
		panic(err)
	}
	manager, err := recording.Open(recording.Config{DataDir: filepath.Join(root, "schedule-data"), DefaultFolder: filepath.Join(root, "schedule-media")})
	if err != nil {
		panic(err)
	}
	defer manager.Close()
	rule := recording.Schedule{ID: "boundary-audit", Kind: "once", Date: start.Format("2006-01-02"), StationID: "fixture", StationName: "Time-coded local audio", StreamURL: server.URL, StartTime: start.Format("15:04"), EndTime: end.Format("15:04"), Timezone: "UTC", Enabled: true}
	rule.PreRollSeconds, rule.PostRollSeconds = int(padding.Seconds()), int(padding.Seconds())
	if err := manager.UpsertSchedule(manager.Snapshot().Revision, rule); err != nil {
		panic(err)
	}
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	deadline := time.NewTimer(time.Until(captureEnd.Add(15 * time.Second)))
	defer deadline.Stop()
	for {
		select {
		case <-deadline.C:
			panic("scheduled capture did not finish")
		case <-ticker.C:
			snapshot := manager.Snapshot()
			if snapshot.Error != "" {
				panic(snapshot.Error)
			}
			if len(snapshot.Recordings) == 0 || snapshot.ActiveCount > 0 {
				continue
			}
			row := snapshot.Recordings[0]
			r := measurement{Source: "scheduled", WindowSeconds: captureEnd.Sub(captureStart).Seconds(), ProgramStartSecond: padding.Seconds(), ProgramEndSecond: padding.Seconds() + 60, FinishedSeconds: time.Since(captureStart).Seconds(), ReportedSeconds: row.DurationSeconds, Bytes: row.Bytes, Status: row.Status, CaptureStartedAt: row.StartedAt, CaptureEndedAt: row.EndedAt, Error: row.Reason}
			if !row.Playable {
				return r
			}
			_, path, err := manager.RecordingPath(row.ID)
			if err != nil {
				panic(err)
			}
			return analyzeAudio(r, path, fixture, captureStart)
		}
	}
}

func main() {
	duration := flag.Duration("duration", 12*time.Second, "capture window (2s to 2m)")
	output := flag.String("output", "build/planning/recording-audit", "new output directory")
	scheduled := flag.Bool("scheduled", false, "exercise a real one-minute schedule at the next UTC minute boundary")
	padding := flag.Duration("schedule-padding", 0, "padding on each side of the scheduled audit (whole seconds, 0s to 30s)")
	fixtures := flag.Bool("fixtures", true, "include local paced, burst and delayed fixtures")
	stationIDs := flag.String("stations", "", "optional comma-separated bundled stations; connects to those broadcasters")
	flag.Parse()
	if *duration < 2*time.Second || *duration > 2*time.Minute {
		panic("duration must be between 2s and 2m")
	}
	if *padding < 0 || *padding > 30*time.Second || *padding%time.Second != 0 || (!*scheduled && *padding != 0) {
		panic("schedule-padding requires --scheduled and whole seconds from 0s to 30s")
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0700); err != nil {
		panic(err)
	}
	if err := os.Mkdir(*output, 0700); err != nil {
		panic(err)
	}
	var reports []measurement
	if *fixtures {
		for _, spec := range []struct {
			id    string
			burst int
			delay time.Duration
		}{{"paced", 0, 0}, {"burst", 8, 0}, {"delayed", 0, 1500 * time.Millisecond}} {
			server, fixture := source(spec.burst, spec.delay)
			r := audit(spec.id, server.URL, *output, *duration, fixture)
			server.Close()
			reports = append(reports, r)
			data, _ := json.Marshal(r)
			fmt.Println(string(data))
		}
	}
	if *stationIDs != "" {
		data, err := os.ReadFile("stations.json")
		if err != nil {
			panic(err)
		}
		var stations []struct{ ID, StreamURL string }
		if err := json.Unmarshal(data, &stations); err != nil {
			panic(err)
		}
		for _, id := range strings.Split(*stationIDs, ",") {
			found := false
			for _, station := range stations {
				if station.ID == id {
					r := audit(id, station.StreamURL, *output, *duration, nil)
					reports = append(reports, r)
					data, _ := json.Marshal(r)
					fmt.Println(string(data))
					found = true
					break
				}
			}
			if !found {
				panic("unknown station identifier")
			}
		}
	}
	if *scheduled {
		r := scheduledAudit(*output, *padding)
		reports = append(reports, r)
		data, _ := json.Marshal(r)
		fmt.Println(string(data))
	}
	data, _ := json.MarshalIndent(reports, "", "  ")
	if err := os.WriteFile(filepath.Join(*output, "report.json"), append(data, '\n'), 0600); err != nil {
		panic(err)
	}
}
