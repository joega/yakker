# Live scheduled recording acceptance check

This opt-in check contacts up to three explicitly selected bundled stations.
It copies the supplied controller binary and selected station catalogue into a
private test bundle. Recording indexes, media, preferences and runtime sockets
are isolated; installed user data, shell settings and audible playback are not
changed. mpv uses null audio. No installation or shell restart is performed.

From the repository root, with Python 3, FFmpeg/libopus and mpv:

```sh
make build
python3 tools/test-scheduled-recordings-unit.py
python3 -u tools/test-scheduled-recordings.py \
  --stations weei-fm,bbc-radio-5-live,wbns-fm \
  --output build/planning/scheduled-station-check
```

To validate installed code, pass
`--controller ~/.config/omarchy/plugins/io.github.joega.yakker/yakker-controller`.
The copied binary's SHA-256 is included in the report. The output directory must
be new. Defaults use 10/15, 20/10 and 30/20 seconds before/after the respective
one-minute shows; override with `--padding 30:60,30:60,30:60`. Padding in this
short audit is limited to 60 seconds per side. The real scheduler uses its normal
one-second poll and three-capture limit. Allow several minutes for scheduling,
capture, independent references, content matching, and playback tests.

For a longer run with staggered, overlapping shows and an independent foreground
station in the same controller:

```sh
python3 -u tools/test-scheduled-recordings.py \
  --controller ~/.config/omarchy/plugins/io.github.joega.yakker/yakker-controller \
  --stations weei-fm,bbc-radio-5-live,kiro-am \
  --minutes 5,6,7 --offsets 0,1,2 --padding 15:30,30:45,45:60 \
  --listen-station wbns-fm \
  --output build/planning/long-scheduled-station-check
```

`--minutes` accepts 1–30 program minutes and `--offsets` accepts 0–10 minutes
after the first start. Either accepts a single value for all stations or one per
station. The optional listening station must differ from all recording stations.
It makes a real mpv connection with silent output. The report samples its state,
station, player PID, decoder progress and concurrent capture count once per second;
the decoder clock is read directly from the isolated mpv socket because the
controller's live-only UI position intentionally stays at zero.
An error, reconnect or player replacement fails the foreground check. Foreground
playback stops before testing recorded-file playback. Reports and progress messages
are checkpointed every 30 seconds while captures run. The example takes about
12 minutes plus content matching and playback checks.

Each station gets an additional longer reference connection. The check:

- Creates real one-time schedules, waits through post-roll and finalization,
  and retains actual program/capture/reader times and partial-status reasons.
- Decodes every saved file and checks the final Ogg EOS page. Exports the first
  and last eight seconds as local WAV files for listening.
- Tests playing from the beginning, pausing, seeking while paused, stopping and
  saving position. Restarts the isolated controller and verifies persisted resume,
  pause/resume, playback through the ending, and resume reset at EOF.
- Correlates eight-second head/tail log-RMS features against longer reference
  audio. Low-confidence, repeated or inconsistent content is reported as
  unavailable, rather than accepted as a successful boundary match.
- Brackets the reference's media delivery at the show's scheduled start/end,
  using FFmpeg progress observations. It independently matches reference clips
  spanning each boundary inside the saved recording. The physical file tail is
  checked separately: different content in extra post-roll does not prove the
  original show ending was missed.

Boundary matching first uses four seconds of context on each side of the entire
reference delivery range. If that fails, it tries two seconds on each side;
independent connections can differ in surrounding content without losing the
boundary itself. Both attempts use the same correlation and ambiguity thresholds.
The report preserves a failed wider-context result when the narrower one succeeds.
It never confirms only adjacent content that excludes the requested delivery range.

`report.json`, controller logs, isolated indexes, complete recordings, references
and head/tail clips remain under the output directory. Samples from broadcasters
are for local inspection; do not commit or redistribute them. `build/planning/`
is ignored. SIGTERM/normal interruption runs cleanup and retains the report.

If an independent reference reader needs a forced stop, its WAV header may still
declare an unfinished stream. The audit preserves that original and writes a
separate `*-reference-recovered.wav` with the received complete 16-bit PCM frames
and a finalized header. At most an incomplete final sample is discarded; no audio
is synthesized. The progress report records the recovery and discarded byte count.
Reference coverage and content confidence still have to pass. This reference-only
repair does not change the saved Opus file or promote a partial recording to complete.

## Limits

This does not establish the broadcaster's true program-clock timestamp. Delivery
can lag broadcast time, HLS arrives in segments, and connections may receive
different ads or content. Progress observations give a range, not a sample-exact
clock mapping. Matching uses 20 ms features and requires strong correlation and
separation from competing matches. Physical head/tail alignment additionally
requires agreement within 200 ms; scheduled boundary clips are matched independently.
Unavailable matching requires manual/reference review. Strongly matched but
uncovered delivery boundaries fail the audit. Inconclusive coverage also returns
a nonzero result; it cannot print a passing audit summary. A reference-finalization
failure preserves its progress evidence and cleanup still attempts every remaining
reference and controller. A finalized file with partial
status still needs its recording note reviewed.

Silent mpv playback validates decoding, seeking and state persistence, not
subjective audio quality. Listen to the retained head/tail clips to judge words,
speech fidelity and whether the desired show content is actually present.
This check does not exercise native UI focus or suspend/resume; use the separate
native UI suite and physical desktop acceptance checks for those.
