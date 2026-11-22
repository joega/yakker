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

# Verify that a padded capture surrounds the original one-minute show.
go run ./tools/recording-audit --fixtures=false --scheduled --schedule-padding 5s \
  --output build/planning/timing-padded

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
`--schedule-padding` adds whole seconds on each side (0–30 seconds in this audit
to keep the frequency sweep measurable; product schedules support 0–10 minutes).
The test waits for a future minute with time to start its pre-roll, then runs
through the post-roll.

## Interpreting a report

- `windowSeconds`: requested computer-clock capture interval, including padding.
- `captureStartedAt` / `captureEndedAt`: stream-reader process lifetime, excluding
  writer drain, FFprobe and manager finalization. These do not identify the broadcaster's
  program timestamp or the first/last retained sample.
- `finishedSeconds`: time through capture finalization. Scheduled results use
  the padded capture start as their origin; direct results use the capture request.
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
  the padded capture start; for direct fixtures they are relative to source sample zero.
  They are unavailable for broadcaster feeds without a known reference signal.
- `programStartSecond` / `programEndSecond`: original show boundaries relative
  to the scheduled capture start. In a 5-second padded test they are 5 and 65;
  retained audio should span both. An omitted start means zero.
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
stalled HLS playlist. Source decoding and Opus writing use separate processes
connected by a bounded float PCM pipe. A stalled reader can be stopped without
interrupting the writer's drain and final Ogg page. Reader stalls still retain a
partial status because missing source audio cannot be ruled out; writer failures
warn separately about an unclean ending. Tests verify received HLS tail retention,
the final EOS page, reader crashes, writer crashes and both children's cleanup.
Run these with `go test ./internal/recording` or
`make check`.
