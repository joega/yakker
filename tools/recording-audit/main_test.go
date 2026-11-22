package main

import (
	"math"
	"testing"
)

func TestChirpPositionFindsRetainedSourceBoundaries(t *testing.T) {
	// The encoded chirp is time-coded by frequency. Check an arbitrary cropped
	// interval as well as the start of the source, independently of file duration.
	for _, start := range []float64{0, 2.75, 8.125} {
		const duration = 1.25
		samples := make([]float64, int(duration*sampleRate))
		for i := range samples {
			seconds := start + float64(i)/sampleRate
			samples[i] = 0.4 * math.Sin(2*math.Pi*(300*seconds+15*seconds*seconds))
		}
		if head := chirpPosition(samples, false); math.Abs(head-start) > 0.01 {
			t.Fatalf("source beginning: got %.4f, want %.4f", head, start)
		}
		if tail := chirpPosition(samples, true); math.Abs(tail-start-duration) > 0.01 {
			t.Fatalf("source end: got %.4f, want %.4f", tail, start+duration)
		}
	}
}
