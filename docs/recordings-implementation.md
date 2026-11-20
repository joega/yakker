# Recordings implementation

Approved scope: bar-plugin lifetime only, mono Opus at **24 kbit/s VBR**, default media folder **`~/Music/Yakker`** (editable), default library cap 5 GiB (editable), 1 GiB free-space reserve, three independent simultaneous jobs. No wake timers, standalone service, automatic file deletion or audio playback at login. Increasing the encoder bitrate later affects new recordings only.

## Bounded work and ownership

1. Capture worker and local HTTP/Opus/probe/playback tests (`internal/recording/capture*.go`).
2. Durable schedules/library/settings, weekly/timezone engine and process lifetime (`internal/recording`, excluding capture files).
3. Controller protocol, recorded-file foreground playback and lifecycle integration (`internal/radio`, coordinator).
4. Native Recordings screen, editor, library and recording storage Settings; installer/release entries (QML agent).
5. Coordinator review, native keyboard/render tests, real overlapping recordings and foreground-independence checks, full build/vet/race/fixture checks, documentation and commits.

Dependencies: agree contracts first; workers 1/2/4 can proceed independently; controller integration consumes 1/2; final native validation consumes all four. Work stays in the checkout until validation. Existing listening, temporary pause, custom stations and favorites must keep working.

## Shared Go contract

Package `internal/recording`, no dependency on `internal/radio`.

Capture worker owns:

```go
type CaptureOptions struct {
    FFmpeg, FFprobe, URL, Path string // Path is a unique .partial output; explicit ogg muxer
    End time.Time                  // wall-clock end; may be zero in focused tests
    StopGrace time.Duration
}
type CaptureResult struct { Bytes int64; DurationSeconds float64; Err error }
type Capture struct { /* private */ }
func StartCapture(ctx context.Context, options CaptureOptions) (*Capture, error)
func (c *Capture) Done() <-chan CaptureResult // exactly one result, then closed
func (c *Capture) Stop()                     // idempotent graceful interrupt, bounded kill/reap
func ProbeRecording(ctx context.Context, ffprobe, path string) (CaptureResult, error)
```

Capture cancellation/end stops FFmpeg gracefully then probes recoverable audio; callers decide complete/partial status based on their stop reason and planned interval. Nonzero process exit/cancel can return recoverable bytes/duration together with Err. No shell interpolation, unbounded diagnostics or raw credential-bearing stream URLs in errors/logs. Linux parent-death protection required.

Manager owns exported models with these JSON names:

- `Settings`: `folder` string (absolute), `storageCapBytes` int64, `freeSpaceReserveBytes` int64, `concurrency` int.
- `Schedule`: `id`, `label`, `stationId`, `stationName`, `streamUrl`, `weekdays` ([]int; 0=Sunday), `startTime`, `endTime` (HH:mm), `timezone` (IANA), `enabled` bool, `nextStart`, `nextEnd` (RFC3339 strings; computed).
- `Recording`: `id`, `scheduleId`, `label`, `stationId`, `stationName`, `plannedStart`, `plannedEnd`, `startedAt`, `endedAt` (RFC3339 strings), `status`, `reason`, `bytes`, `durationSeconds`, `folder`, `filename`. Status: `recording`, `complete`, `partial`, `missed`, `error`, `missing`. Optional `parentId` for resumed segments.
- `Snapshot`: `revision` int64, `settings`, `schedules` (array), `recordings` (array newest first), `available` bool, `error` string, `usedBytes` int64, `activeCount` int. Empty collections serialize as arrays.
- `Config`: `DataDir`, `DefaultFolder`, `FFmpeg`, `FFprobe` strings; `PollInterval`, `StopGrace` durations; `Now func() time.Time` for deterministic tests. Default persistent index under `$XDG_DATA_HOME/yakker`; configured directory used verbatim for isolated tests. Opening a manager must not create the media folder or launch a recorder until needed.

```go
func Open(config Config) (*Manager, error)
func (m *Manager) Snapshot() Snapshot
func (m *Manager) Updates() <-chan struct{} // buffered/coalesced notification, callers read Snapshot
func (m *Manager) SetSettings(expectedRevision int64, settings Settings) error
func (m *Manager) UpsertSchedule(expectedRevision int64, schedule Schedule) error
func (m *Manager) DeleteSchedule(expectedRevision int64, id string) error
func (m *Manager) StopRecording(expectedRevision int64, id string) error
func (m *Manager) DeleteRecording(expectedRevision int64, id string) error
func (m *Manager) RecordingPath(id string) (Recording, string, error) // retained managed regular files only
func (m *Manager) Close() error // all workers reaped, partial output persisted, safe repeated calls
```

All methods safe for concurrent use. Serialized revisioned writes must be persisted before success/publication. Stale revisions reject without mutating memory/files. Preserve corrupt data and expose errors while leaving normal radio usable. Folder changes affect future recordings; old files remain accessible and count toward cap. No deletion of an active recording; stop it first. Persist deletion intent/recoverable ordering. Validate identifiers, paths, text, settings, schedules, JSON sizes and collection bounds; reject impossible schedules and arbitrary file access.

Engine checks current wall time repeatedly, uses explicit timezone/DST semantics from the proposal, suppresses duplicate occurrences across reloads/clock jumps, reports missed intervals and captures only the remainder of an in-progress interval. Interrupted jobs retain partial output and may start linked remainder segments. Editing/disabling/deleting a schedule affects future jobs; explicit Stop ends an active job. Monitor aggregate bytes/free space during captures and stop with a clear reason on limits/errors. A long wall-clock gap during a job marks an interruption. No busy polling or network work without a due schedule.

## Controller/QML protocol

Desktop controller opens the recording manager only for its normal bar-owned configuration. Explicit station-file/URL terminal sessions and existing tests remain isolated unless a recording Config override is supplied. Failure to open the recorder publishes `recordings.available=false`/error and does not break listening.

Status additions:

- `recordings`: Snapshot above.
- `recordingMutationSerial` int64, `recordingMutationOK` bool, `recordingError` string. Mutations acknowledge their own request serial. UI panels bind local pending/error state to the exact serial, without closing other monitor editors.
- `playbackKind`: `live` or `recording`; `recordingId`, `recordingTitle`, `duration` (seconds). Existing `position` serves file playback too. Existing selected `station` remains available for return to live.

Commands (existing `serial` field retained):

```text
recordingSettings { revision, settings }
upsertSchedule    { revision, schedule }
deleteSchedule    { revision, id }
stopRecording     { revision, id }
deleteRecording   { revision, id }
playRecording     { id }
seekRecording     { value } // finite absolute seconds, clamped to file duration
```

For upsertSchedule, UI sends stationId only for station identity. Controller resolves it against the actual merged catalogue and supplies stationName/streamUrl; edits retain the saved station snapshot when identity/URL refresh is not explicitly requested. Unknown stations reject new schedules. Manager snapshots own already-running jobs, unaffected by later station edits/removal.

`playRecording` replaces only the foreground mpv player. Pause/resume/volume/mute work for files, EOF stops instead of reconnecting; file playback never enables live DVR caching. Live Play/Go live/station selection returns to the selected station. Controller `quit`, EOF, context cancel and parent death clean up recorder children; ordinary foreground `stop` does not. No playback intent is persisted. Controller state remains authoritative.

## UI scope

Use the real native qs.Ui controls and qualified Commons.Color; text stays PlainText. Recordings navigation has Back, a weekly schedule editor (station, label, weekdays, HH:mm start/end, timezone, enabled, next occurrence preview), schedule edit/enable/delete actions, newest-first library with status/size/time/reason, file play/seek/stop/delete actions, and storage folder/cap Settings. User can type an absolute folder path or use a supported native folder chooser. Show unavailable/empty/working/error states and current storage usage. Preserve other settings/favorites and keyboard behavior; inputs must block global radio hotkeys. Explicit delete confirmation and per-panel revision/serial fencing required. Add every new QML component to installer/release lists.
