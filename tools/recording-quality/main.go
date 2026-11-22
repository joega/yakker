// recording-quality prepares a local, matched-source listening comparison.
package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type sample struct {
	File             string  `json:"file"`
	Bitrate          string  `json:"bitrate,omitempty"`
	Bytes            int64   `json:"bytes"`
	Seconds          float64 `json:"seconds"`
	RMSDB            float64 `json:"rmsDB"`
	PeakDB           float64 `json:"peakDB"`
	FullScaleSamples int     `json:"fullScaleSamples"`
}

func ffmpeg(args ...string) []byte {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ffmpeg", append([]string{"-v", "error", "-nostdin", "-n"}, args...)...).Output()
	if err != nil {
		panic("FFmpeg conversion failed; check the local input and available codecs")
	}
	return out
}

func inspect(path, bitrate string) sample {
	pcm := ffmpeg("-i", path, "-ac", "1", "-ar", "48000", "-f", "f64le", "pipe:1")
	info, err := os.Stat(path)
	if err != nil {
		panic(err)
	}
	r := sample{File: filepath.Base(path), Bitrate: bitrate, Bytes: info.Size(), Seconds: float64(len(pcm)/8) / 48000}
	var sum, peak float64
	for i := 0; i+8 <= len(pcm); i += 8 {
		x := math.Float64frombits(binary.LittleEndian.Uint64(pcm[i:]))
		if math.IsNaN(x) || math.IsInf(x, 0) {
			panic("invalid decoded sample")
		}
		sum += x * x
		peak = math.Max(peak, math.Abs(x))
		if math.Abs(x) >= 0.9999 {
			r.FullScaleSamples++
		}
	}
	r.RMSDB = 10 * math.Log10(math.Max(1e-20, sum/math.Max(1, float64(len(pcm)/8))))
	r.PeakDB = 20 * math.Log10(math.Max(1e-10, peak))
	return r
}

func main() {
	input := flag.String("input", "", "local reference audio file (no network input)")
	output := flag.String("output", "build/planning/recording-quality", "new output directory")
	duration := flag.Duration("duration", 20*time.Second, "comparison length (5s to 60s)")
	flag.Parse()
	info, err := os.Stat(*input)
	if err != nil || !info.Mode().IsRegular() {
		panic("input must be an existing local audio file")
	}
	if *duration < 5*time.Second || *duration > time.Minute {
		panic("duration must be between 5s and 60s")
	}
	if err := os.MkdirAll(filepath.Dir(*output), 0700); err != nil {
		panic(err)
	}
	if err := os.Mkdir(*output, 0700); err != nil {
		panic(err)
	}
	reference := filepath.Join(*output, "reference.wav")
	// All variants start with exactly the same mono 48 kHz reference. Do not
	// normalize or change gain between encodes; preserve Opus pre-skip on decode.
	ffmpeg("-protocol_whitelist", "file,pipe", "-i", *input, "-map", "0:a:0", "-t", fmt.Sprint(duration.Seconds()), "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_f32le", reference)
	rates := []string{"24k", "48k"}
	var order [1]byte
	if _, err := rand.Read(order[:]); err != nil {
		panic(err)
	}
	if order[0]&1 != 0 {
		rates[0], rates[1] = rates[1], rates[0]
	}
	report := []sample{inspect(reference, "")}
	for i, rate := range rates {
		path := filepath.Join(*output, string(rune('A'+i))+".opus")
		ffmpeg("-i", reference, "-map", "0:a:0", "-ac", "1", "-c:a", "libopus", "-b:a", rate, "-vbr", "on", "-page_duration", "200000", "-flush_packets", "1", "-f", "ogg", path)
		report = append(report, inspect(path, rate))
	}
	data, err := json.MarshalIndent(report, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(*output, "comparison.json"), append(data, '\n'), 0600); err != nil {
		panic(err)
	}
	note := `# Recording quality comparison

Listen to reference.wav, A.opus and B.opus at the same player volume and speed.
The A/B bitrate order is randomized; comparison.json contains the answer and
48 kHz decode statistics. Do not open it until you have compared the samples.

Check speech clarity, sibilants, music, crowd noise, gaps and the first/last words.
Repeat short passages and record whether you can consistently distinguish A/B,
which you prefer, and whether the difference warrants the larger file size.
There is no automatic subjective quality score. This is a small listening
comparison, not a statistically validated blind test. No audio is played or
uploaded by this tool. The production recording setting is unchanged.
`
	if err := os.WriteFile(filepath.Join(*output, "LISTEN.md"), []byte(note), 0600); err != nil {
		panic(err)
	}
	fmt.Printf("Prepared reference.wav, A.opus and B.opus in %s\n", *output)
}
