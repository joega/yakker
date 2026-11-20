package radio

import (
	"errors"
	"math"
	"time"
)

// The native mpv packet cache stays in memory. Bounds describe only the latest
// contiguous seekable range, so controls cannot trigger a network seek or cross
// holes in the cache. Forward and backward caches each have a hard byte cap.
type cacheWindow struct {
	start, end   float64
	forwardBytes float64
	valid, idle  bool
}

func (p *player) consumeCache(event mpvEvent) bool {
	if event.Event != "property-change" || event.Name != "demuxer-cache-state" {
		return false
	}
	data, ok := event.Data.(map[string]any)
	if !ok {
		return true
	}
	window := cacheWindow{}
	window.idle, _ = data["idle"].(bool)
	window.forwardBytes, _ = data["fw-bytes"].(float64)
	ranges, _ := data["seekable-ranges"].([]any)
	for _, item := range ranges {
		span, ok := item.(map[string]any)
		if !ok {
			continue
		}
		start, ok1 := span["start"].(float64)
		end, ok2 := span["end"].(float64)
		if !ok1 || !ok2 || math.IsNaN(start) || math.IsNaN(end) || math.IsInf(start, 0) || math.IsInf(end, 0) || end <= start {
			continue
		}
		if !window.valid || end > window.end {
			window.start, window.end, window.valid = start, end, true
		}
	}
	p.cacheMu.Lock()
	if window.valid && (!p.cache.valid || window.end > p.cache.end+.01) {
		p.lastIntake.Store(time.Since(p.started).Nanoseconds())
	}
	p.cache = window
	p.cacheMu.Unlock()
	return true
}
func (r *controller) currentPosition() float64 {
	if r.player == nil {
		return 0
	}
	return math.Float64frombits(r.player.position.Load())
}
func (r *controller) setPaused(paused bool) error {
	if paused && r.cfg.DVRWindow == 0 {
		return errors.New("Enable a buffer before pausing")
	}
	if !r.state.Wanted || r.player == nil {
		return errors.New("Start playback before pausing or resuming")
	}
	if paused == r.state.Paused {
		return nil
	}
	if err := r.ipc([]any{"set_property", "pause", paused}); err != nil {
		return err
	}
	if paused != r.state.Paused && r.player.conn != nil {
		r.player.playbackSince = time.Since(r.player.started)
		r.after("deadline", r.cfg.StallTimeout)
	}
	r.state.Paused = paused
	r.state.Position = r.currentPosition()
	if paused {
		r.state.State = "paused"
	} else {
		r.state.BufferExpired = false
		if r.state.State == "paused" {
			r.state.State = "playing"
		}
	}
	return nil
}
func (r *controller) seekDVR(target float64) error {
	if !r.state.Wanted || r.player == nil || !r.state.DVR {
		return errors.New("No buffered audio is available yet")
	}
	if math.IsNaN(target) || math.IsInf(target, 0) {
		return errors.New("Seek must be a finite number of seconds")
	}
	r.player.cacheMu.Lock()
	cache := r.player.cache
	r.player.cacheMu.Unlock()
	if !cache.valid {
		return errors.New("No continuous buffered range is available")
	}
	r.state.BufferStart = math.Max(cache.start, cache.end-r.cfg.DVRWindow.Seconds())
	r.state.BufferEnd = cache.end
	end := math.Max(r.state.BufferStart, r.state.BufferEnd-.25)
	target = math.Max(r.state.BufferStart, math.Min(end, target))
	if err := r.ipc([]any{"seek", target, "absolute+exact"}); err != nil {
		return err
	}
	r.state.BufferExpired = false
	return nil
}
func (r *controller) updateDVR() {
	p := r.player
	if p == nil {
		return
	}
	p.cacheMu.Lock()
	cache := p.cache
	p.cacheMu.Unlock()
	if !cache.valid {
		return
	}
	first := !r.state.DVR
	r.state.DVR = true
	r.state.BufferEnd = cache.end
	r.state.BufferStart = math.Max(cache.start, cache.end-r.cfg.DVRWindow.Seconds())
	position := r.currentPosition()
	// Advance an expired paused bookmark while staying paused. The extra forward
	// read-ahead lets intake continue beyond the visible retention window. If a
	// high-bitrate stream fills the byte cap first, retain the available window.
	if first && !r.state.Paused && cache.end-position > 3 {
		_ = r.seekDVR(cache.end - 1)
		_ = r.publish()
		return
	}
	expired := position < r.state.BufferStart
	capacity := r.state.Paused && cache.idle && cache.forwardBytes >= float64(r.cfg.DVRBytes)*.9 && cache.end-position > 5
	if expired || capacity {
		target := r.state.BufferStart
		if capacity {
			target = math.Max(target, position+2)
		}
		if err := r.seekDVR(target); err == nil {
			r.state.BufferExpired = true
		}
	}
	r.state.Position = math.Max(r.state.BufferStart, math.Min(cache.end, position))
	_ = r.publish()
}

func dvrByteLimit(window time.Duration) int64 {
	switch {
	case window == 0:
		return 2 * 1024 * 1024
	case window <= 5*time.Minute:
		return 16 * 1024 * 1024
	case window <= 15*time.Minute:
		return 32 * 1024 * 1024
	default:
		return 64 * 1024 * 1024
	}
}
