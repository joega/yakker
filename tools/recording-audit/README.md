# Recording timing audit

Run from the repository root with Go, FFmpeg (including libopus), and FFprobe.
This uses the production capture code with separate local media and metadata.
It does not use the installed controller, change your schedules, play audio,
or restart the shell. Output directories must be new; existing results are never
overwritten. `build/planning/` is ignored by Git.

```sh
# Three local fixtures, 12 seconds each: paced audio, an 8-second initial burst,
# and a source with a 1.5-second connection delay.
go run ./tools/recording-audit --output build/planning/timing-local

# Exercise the real scheduler, its default one-second poll, and a once rule.
# Waits for the next UTC minute, then records one minute of time-coded audio.
go run ./tools/recording-audit --fixtures=false --scheduled \
  --output build/planning/timing-scheduled

# Optional: connects to the selected broadcasters, sequentially.
go run ./tools/recording-audit --fixtures=false --duration 24s \
  --stations wbz-fm,weei-fm,bbc-radio-5-live \
  --output build/planning/timing-stations
```

`--duration` accepts 2 seconds through 2 minutes for direct captures. It does not
change the one-minute scheduled test. Each run saves the audio and `report.json`;
the scheduled test also retains its isolated recording index. Fixture servers
listen on loopback only. Broadcaster samples are for local inspection, not
redistribution.

## Interpreting a report

- `windowSeconds`: requested computer-clock interval.
- `encoderStartedAt` / `encoderEndedAt`: encoder process lifetime, excluding
  later FFprobe and manager finalization. These do not identify the broadcaster's
  program timestamp or the first/last retained sample.
- `finishedSeconds`: time through capture finalization. Scheduled results use
  the planned start as their origin; direct results use the capture request.
- `reportedSeconds`: file duration obtained by FFprobe.
- `decodedSeconds`: retained audio decoded to mono 16 kHz PCM. A small difference
  from the container duration can reflect Opus priming. Several extra seconds
  should be investigated as actual additional audio, not assumed to be metadata.
- `requestSeconds`: local fixture connection time relative to the same origin.
- `firstWriteSeconds`: first observed nonempty output, for direct captures.
  Input probing and muxer buffering can delay this even when beginning audio
  is retained; it is not a measure of missing beginning audio.
- `firstSourceSecond` / `lastSourceSecond`: estimated source positions derived
  from the fixture's frequency sweep. For scheduled tests these are relative to
  the planned start; for direct fixtures they are relative to source sample zero.
  They are unavailable for broadcaster feeds without a known reference signal.
- `sourceSamplesDelivered`: samples written by the fixture server, including
  data the receiver may not retain.
- `rmsDB`, `peakDB`, `clippedSamples`: basic statistics of the decoded 16 kHz PCM.
  These can reveal silence or clipping in that representation; they do not
  measure speech intelligibility, source fidelity, or subjective codec quality.
- `status`, `error`, `decodeError`: scheduled result state, capture/recording
  reason, and decoding failure respectively. Inspect them before interpreting
  audio statistics. A playable partial is not a successful complete capture.

The initial burst fixture demonstrates why wall time and audio duration can
differ. Live feeds may supply buffered audio immediately, and HLS supplies audio
in segments. Do not trim recordings to the requested wall duration or subtract a
fixed offset without knowing which program audio that would remove. Scheduled
tests measure local boundaries; verifying a broadcaster's actual program
beginning/end requires a reference to that broadcast.

The automated capture tests additionally cover early EOF observed after the
deadline, delayed probing, expired capture deadlines, stalled PCM input, and a
stalled HLS playlist. A stalled HLS reader may require a bounded hard stop, lose
buffered ending audio, and leave a playable partial. The manager reports that
unclean ending explicitly. Run these with `go test ./internal/recording` or
`make check`.
