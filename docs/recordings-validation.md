# Recordings validation

Validated on 2026-11-20 with mono Opus at 24 kbit/s VBR. The default media folder
is `~/Music/Yakker`; tests used isolated temporary folders and settings.

## Automated checks

```sh
YAKKER_TEST_REAL_MPV=1 make check
python3 tools/test-recordings-ui.py
```

The full check passed formatting, vet, module verification and race-enabled Go
tests. Real media tests use local paced HTTP audio and mpv's null audio sink.
They cover:

- Independent simultaneous captures alongside foreground playback, Stop and
  station changes; recorded-file playback, pause, seek and return to live.
- Graceful and forced process termination, child reaping, partial-file probing,
  recovery and bounded stream-failure retries. Early termination while FFmpeg is
  still opening/probing a source can leave an empty, unplayable partial.
- Weekly schedules, overnight intervals, IANA timezones, DST gaps/folds,
  clock changes, duplicate suppression and linked remainder segments.
- Stale-revision rejection, immutable active-job snapshots, explicit saved-source
  refresh and read-only previews without starting playback or recording.
- Aggregate cap/free-space enforcement, unavailable folders, folder changes,
  returning retained files, safe deletion, filename collisions, failed writes,
  atomic-replacement recovery and immediate capture shutdown on metadata failure.
- Bounded index/history state and deduplication compaction that preserves audio
  and recording history. Old unavailable periods use grouped missed summaries.

The reproducible native test uses the real controller and installed Omarchy
`qs.Ui` controls. QtTest sends actual key events. It passed navigation, preview,
schedule persistence, stale-draft refresh, isolation of another panel's draft,
storage navigation/focus at 650 px and 300 px window heights, file controls,
favorites/custom-station input and bounded helper recovery without foreground
autoplay. Screenshots are written to `/tmp/yakker-recordings-ui-qa`.

The native test substitutes a windowed container for `KeyboardPanel` and uses
temporary data. It does not change the installed plugin or verify the real
compositor popup's geometry/focus behavior.

## Bounded broadcaster and CPU checks

A capture from the configured WBZ-FM source produced 89,000 bytes of mono Ogg
Opus. After 20.6 seconds of wall-clock capture, ffprobe reported 28.38 seconds of
media; mpv decoded it and started partway through it with null audio. The cause of
the duration difference was not established. This demonstrates capture/playback
for that tested response, without establishing exact broadcast-boundary accuracy
or compatibility with every station.

Three simultaneous encoders against a paced local mono PCM tone used 0.504 CPU
seconds over 12.417 wall seconds, about 4.06% of one CPU core combined on this
machine. This is one bounded fixture measurement; content, tools and hardware can
change the result.

## Manual acceptance still outstanding

In-speaker listening for the chosen talk-radio quality, physical sleep/resume,
full installed-shell restart/removal, and actual layer-shell popup behavior have
not been manually verified. The scheduler's interruption/recovery rules have
automated coverage. No real recurring user schedule was created during testing.
