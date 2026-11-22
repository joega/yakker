# Recording recovery acceptance check

Run from the repository root with Python 3, a built controller, FFmpeg/libopus,
FFprobe and mpv:

```sh
make build
python3 -u tools/test-recording-recovery.py \
  --output build/planning/recording-recovery-check
```

The output directory must be new. This uses a time-coded WAV source served only
on loopback, actual one-minute schedules with five seconds of padding on each
side, production FFmpeg capture, and silent mpv playback. Each case gets its own
controller and private XDG recording data/config/runtime. No broadcaster
connections, installed user-data edits, shell restarts, or installation occur.
Allow a few minutes for all cases; schedules run concurrently in isolated cases.

Pass `--controller /absolute/path/to/yakker-controller` to test another binary.
Its checksum is recorded in the top-level report. A focused run is also possible:

```sh
python3 -u tools/test-recording-recovery.py --cases stall-once,forced-restart \
  --output build/planning/recovery-focused
```

## Cases

| Case | Failure injection and expected recovery |
| --- | --- |
| `drop-once` | Close the first stream after eight seconds; retain a playable partial and retry into one linked remainder. |
| `stall-once` | Stop sending audio after eight seconds while keeping the connection open; the 15-second input timeout and bounded retry create a linked remainder. |
| `retry-limit` | Drop every connection after four seconds; restart during persisted backoff and again after exhaustion. There must be exactly three attempts with increasing delay and an explicit retry-limit note. |
| `graceful-restart` | Edit/disable the future schedule and change its station, then quit the active controller and reopen after two seconds. The linked remainder must retain the original source, label and padded window. |
| `forced-restart` | Kill the controller while it writes audio. Its reader/writer children must exit, the original audio must be retained, and a linked remainder must start after reopening. |
| `empty-start` | Return HTTP 503 twice before audio headers; those entries stay errors without playable audio. The final allowed attempt captures a linked remainder. |
| `manual-stop` | Explicitly stop capture, then reopen. Preserve the partial and its reason without an automatic retry. |
| `expired-restart` | Kill the controller, wait until the padded window expires, then reopen. Retain recoverable audio without a new capture or stale resume intent. |

The checks verify occurrence identity, parent links, immutable source/window
metadata, durable backoff and retry counts, partial/error states, strict audio
decoding, real controller playback, normal final Ogg pages, and unchanged hashes
of audio retained across restart. After a forced exit, a valid partial can lack
the final EOS page; it must still decode and play. Recovery must preserve a known
capture end, or leave it unknown, rather than using the restart time.

Each case retains `report.json`, protocol logs, its recording index and media.
The frequency sweep identifies where each saved segment begins and ends in the
continuous source timeline. Reports include gaps between linked audio segments;
recovery does not fill missing audio or pretend the result is seamless. The
input-timeout bound concerns the controlled stream, not every broadcaster or
network failure. These checks do not simulate physical suspend/resume or power
loss, and silent playback does not assess subjective audio quality.

Results under `build/planning/` stay ignored. Production unit/race tests also
cover recovery timestamps, transactional resume, storage failures, retry limits
and persisted backoff; run `YAKKER_TEST_REAL_MPV=1 make check` for the full suite.
