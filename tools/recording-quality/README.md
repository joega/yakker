# Matched-source recording quality comparison

Run from the repository root with Go and FFmpeg/libopus. Use a local source file
that has not already been compressed by Yakker: comparing higher bitrates made
from a 24 kbit/s recording cannot restore what that recording discarded.

```sh
go run ./tools/recording-quality --input /absolute/path/to/source.wav \
  --duration 20s --output build/planning/quality-comparison
```

The output directory must be new. The tool takes up to 20 seconds by default
(5–60 seconds allowed), produces a mono 48 kHz float PCM reference, and encodes
the identical reference at 24 and 48 kbit/s Opus VBR. A/B filenames randomize the
bitrate order. There is no normalization or gain change between variants. It
also saves per-file size, decoded duration, RMS, peak and full-scale sample
counts measured at 48 kHz in `comparison.json`. Float PCM measurement preserves
overshoots that an integer decode would clip. Counts indicate levels near or
above full scale, not a subjective quality score or a source-clipping diagnosis.

Follow `LISTEN.md` before opening the answer in `comparison.json`. Use the same
player, speed, and volume; compare short passages against the reference. Listen
for consonants/sibilants, background music, crowd noise, gaps and head/tail words.
The comparison is exploratory rather than a formal ABX test. A short clip cannot
establish quality for every broadcaster or all program material.

This tool accepts local input only, never overwrites existing results, and does
not play, upload, install, or change production recording settings. Outputs under
`build/planning/` stay ignored. Keep broadcaster samples local.
