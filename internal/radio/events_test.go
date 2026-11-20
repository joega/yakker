package radio

import (
	"bytes"
	"encoding/json"
	"io"
	"testing"
	"testing/synctest"
	"time"
)

func TestProgressExtendsDeadlineWithoutPublishing(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var output bytes.Buffer
		r := &controller{cfg: Config{StallTimeout: 30 * time.Second}, state: Status{State: "playing"}, player: &player{started: time.Now()}, output: json.NewEncoder(&output)}
		defer r.clearTimer()
		r.after("deadline", 30*time.Second)
		time.Sleep(10 * time.Second)
		r.player.consumeProgress(mpvEvent{Event: "property-change", Name: "time-pos", Data: 123.5})
		time.Sleep(20 * time.Second)
		<-r.timer.C // A check is due; recent progress must extend, not fail it.
		if remaining := r.watchdogRemaining(); remaining != 10*time.Second {
			t.Fatal("incorrect remaining deadline", remaining)
		} else {
			r.after("deadline", remaining)
		}
		time.Sleep(9 * time.Second)
		select {
		case <-r.timer.C:
			t.Fatal("old stall deadline fired after progress")
		default:
		}
		if output.Len() != 0 {
			t.Fatal("progress published an unnecessary UI update")
		}
		time.Sleep(time.Second)
		select {
		case <-r.timer.C:
		default:
			t.Fatal("new stall deadline did not fire")
		}
	})
}
func TestProgressCannotHideConnectionTimeout(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := &controller{cfg: Config{StallTimeout: 30 * time.Second}, state: Status{State: "connecting"}, player: &player{started: time.Now()}, output: json.NewEncoder(io.Discard)}
		defer r.clearTimer()
		r.after("deadline", 25*time.Second)
		time.Sleep(20 * time.Second)
		r.player.consumeProgress(mpvEvent{Event: "property-change", Name: "time-pos", Data: 123.5})
		if r.watchdogRemaining() != 0 {
			t.Fatal("progress may not postpone a connection timeout")
		}
		time.Sleep(5 * time.Second)
		select {
		case <-r.timer.C:
		default:
			t.Fatal("progress during buffering postponed connection deadline")
		}
	})
}
func TestStoppedDeadlineCannotFireDuringNewBackoff(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		r := &controller{}
		defer r.clearTimer()
		r.after("deadline", time.Second)
		time.Sleep(time.Second)
		r.clearTimer() // Explicit Stop must cancel even an already expired deadline.
		r.after("retry", 5*time.Second)
		time.Sleep(4 * time.Second)
		select {
		case <-r.timer.C:
			t.Fatal("stale deadline fired during backoff")
		default:
		}
		time.Sleep(time.Second)
		select {
		case <-r.timer.C:
		default:
			t.Fatal("new retry deadline did not fire")
		}
	})
}
func TestPropertyEventsOnlyPublishActualChanges(t *testing.T) {
	var output bytes.Buffer
	r := &controller{state: Status{State: "playing", Volume: 65}, output: json.NewEncoder(&output)}
	defer r.clearTimer()
	r.event(mpvEvent{Event: "property-change", Name: "volume", Data: float64(65)})
	if output.Len() != 0 {
		t.Fatal("unchanged volume published")
	}
	r.event(mpvEvent{Event: "property-change", Name: "volume", Data: float64(66)})
	r.event(mpvEvent{Event: "property-change", Name: "mute", Data: true})
	r.event(mpvEvent{Event: "property-change", Name: "metadata", Data: map[string]any{"icy-title": "Actual title"}})
	r.event(mpvEvent{Event: "property-change", Name: "metadata", Data: map[string]any{"icy-title": "Actual title"}})
	decoder := json.NewDecoder(&output)
	for i, want := range []Status{{Volume: 66}, {Volume: 66, Muted: true}, {Volume: 66, Muted: true, Title: "Actual title"}} {
		var got Status
		if err := decoder.Decode(&got); err != nil {
			t.Fatal(err)
		}
		if got.Volume != want.Volume || got.Muted != want.Muted || got.Title != want.Title {
			t.Fatalf("update %d: %+v", i, got)
		}
	}
	var extra Status
	if err := decoder.Decode(&extra); err != io.EOF {
		t.Fatalf("duplicate update: %+v %v", extra, err)
	}
}
func TestTypedEventEnvelopePreservesPropertyTypes(t *testing.T) {
	for _, raw := range []string{
		`{"event":"property-change","name":"time-pos","data":42.5}`,
		`{"event":"property-change","name":"volume","data":null}`,
		`{"event":"property-change","name":"mute","data":false}`,
		`{"event":"property-change","name":"metadata","data":{"icy-title":"Live"}}`,
		`{"event":"end-file","reason":"error","file_error":"loading failed"}`,
		`{"request_id":1,"error":"success","data":true}`,
	} {
		var event mpvEvent
		if err := json.Unmarshal([]byte(raw), &event); err != nil {
			t.Fatal(err)
		}
	}
	for _, raw := range []string{`{"event":"property-change","name":"time-pos","data":1e999}`, `{"event":"property-change","data":NaN}`, `["invalid"]`} {
		var event mpvEvent
		if err := json.Unmarshal([]byte(raw), &event); err == nil {
			t.Fatalf("accepted malformed event %s", raw)
		}
	}
}

func TestInvalidOrOldProgressCannotKeepAPlayerAlive(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		old := &player{started: time.Now()}
		current := &player{started: time.Now()}
		r := &controller{cfg: Config{StallTimeout: 30 * time.Second}, state: Status{State: "playing"}, player: current}
		time.Sleep(25 * time.Second)
		old.consumeProgress(mpvEvent{Event: "property-change", Name: "time-pos", Data: 12.5})
		for _, invalid := range []any{nil, "123", true, map[string]any{}} {
			current.consumeProgress(mpvEvent{Event: "property-change", Name: "time-pos", Data: invalid})
		}
		if remaining := r.watchdogRemaining(); remaining != 5*time.Second {
			t.Fatal("old/invalid heartbeat extended the new player", remaining)
		}
		time.Sleep(5 * time.Second)
		if r.watchdogRemaining() > 0 {
			t.Fatal("stalled player was kept alive")
		}
	})
}
