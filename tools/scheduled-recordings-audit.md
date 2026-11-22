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

`report.json`, controller logs, isolated indexes, complete recordings, references
and head/tail clips remain under the output directory. Samples from broadcasters
are for local inspection; do not commit or redistribute them. `build/planning/`
is ignored. SIGTERM/normal interruption runs cleanup and retains the report.

## Limits

This does not establish the broadcaster's true program-clock timestamp. Delivery
can lag broadcast time, HLS arrives in segments, and connections may receive
different ads or content. Progress observations give a range, not a sample-exact
clock mapping. Matching uses 20 ms features and requires strong correlation and
separation from competing matches. Physical head/tail alignment additionally
requires agreement within 200 ms; scheduled boundary clips are matched independently.
Unavailable matching requires manual/reference review. Strongly matched but
uncovered delivery boundaries fail the audit. A finalized file with partial
status still needs its recording note reviewed.

Silent mpv playback validates decoding, seeking and state persistence, not
subjective audio quality. Listen to the retained head/tail clips to judge words,
speech fidelity and whether the desired show content is actually present.
This check does not exercise native UI focus or suspend/resume; use the separate
native UI suite and physical desktop acceptance checks for those.
