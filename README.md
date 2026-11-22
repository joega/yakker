# Yakker

A native player for curated sports, news, and talk radio on the Omarchy / Quattro
bar. Listen live, pause and rewind, or save a show for later—without a browser.

- **37 stations** across the US, Canada, UK, and Ireland, with Sports, News,
  search, and Favorites filters. Add your own stations when needed.
- **Pause and rewind** with an in-memory replay buffer and one-click Go live.
- **Record now or schedule shows**, with padding, recovery, and saved-position resume.
- **Keep listening while browsing** Library, Schedules, or Settings; playback
  controls remain available and the bar shows playback and recording status.

[Install](#install-locally) · [Listen](#listen) · [Recordings](#scheduled-recordings) · [Stations](#stations) · [Terminal player](#terminal-player) · [Troubleshooting](#troubleshooting)

<table>
  <thead>
    <tr>
      <th>Live radio</th>
      <th>Pause and rewind</th>
      <th>Recording library</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td valign="top" align="center"><a href="docs/yakker-popup.png?v=1.8.0"><img src="docs/yakker-popup.png?v=1.8.0" alt="Focus player with full station title, on-demand favorites, prominent Play/Pause, and compact volume controls" width="240"></a></td>
      <td valign="top" align="center"><a href="docs/yakker-dvr.png?v=1.8.0"><img src="docs/yakker-dvr.png?v=1.8.0" alt="Paused radio with 15 minutes of history, a seek timeline, and Go live" width="240"></a></td>
      <td valign="top" align="center"><a href="docs/yakker-recordings.png?v=1.8.0"><img src="docs/yakker-recordings.png?v=1.8.0" alt="Grouped recovered shows with part counts, Resume actions, and persistent playback controls" width="240"></a></td>
    </tr>
  </tbody>
</table>

<table>
  <thead>
    <tr>
      <th>Station picker</th>
      <th>Upcoming recordings</th>
      <th>Listening settings</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td valign="top" align="center"><a href="docs/yakker-stations.png?v=1.8.0"><img src="docs/yakker-stations.png?v=1.8.0" alt="Sports and News category filters with search and Favorites in the station picker" width="240"></a></td>
      <td valign="top" align="center"><a href="docs/yakker-schedules.png?v=1.8.0"><img src="docs/yakker-schedules.png?v=1.8.0" alt="Upcoming shows with padded capture windows and paused schedules grouped below" width="240"></a></td>
      <td valign="top" align="center"><a href="docs/yakker-settings.png?v=1.8.0"><img src="docs/yakker-settings.png?v=1.8.0" alt="Tabbed settings with Listening, Storage, Alerts, and Stations sections" width="240"></a></td>
    </tr>
  </tbody>
</table>

_Select an image to enlarge it. Screenshots use illustrative data and a mix of
Sports and News stations; Yakker follows your active Omarchy theme._

## What’s new in 1.8

Recovered recording parts now share one expandable library entry, with Resume
opening the right part. The station picker adds **All / Sports / News** and
13 curated news/public-radio stations; Favorites stays inside the picker.
See the [v1.8.0 release notes](docs/releases/1.8.0.md) for the full changes and
upgrade details.

## Install locally

### Requirements

- **Desktop widget:** Omarchy / Quattro with its native `qs.Ui` controls, plus mpv.
  Tested with Omarchy 4.5.0, Quickshell 0.3.2, Qt 6.12, and mpv 0.41.
- **Recording:** FFmpeg with `libopus`, and ffprobe.
- **Source builds:** Go 1.26+ and Make. Compiled downloads need neither.
- **Terminal playback:** Linux, mpv, and working audio; Omarchy and Qt are optional.

### Compiled download

Get the matching Linux amd64 or arm64 archive and its checksum from
[Releases](https://github.com/joega/yakker/releases/latest). For example:

```sh
sha256sum -c yakker-1.8.0-linux-amd64.tar.gz.sha256
tar -xzf yakker-1.8.0-linux-amd64.tar.gz
cd yakker
./yakker install
```

Keep the extracted folder together: the executables use its catalogue and assets.
ARM64 is cross-built; playback on physical ARM64 hardware remains unverified.

### From source

```sh
git clone https://github.com/joega/yakker.git
cd yakker
make build
./yakker install
```

The installer validates and copies the widget to
`~/.config/omarchy/plugins/io.github.joega.yakker`, then enables it beside the
center island. Existing widgets keep their position and preferences. Keep your
checkout or extracted folder at a stable path and reinstall from that same path;
the installer refuses a different source or directly edited installed files.
Previous plugin files are retained in `~/.config/omarchy/plugin-backups/`.

### Upgrading

Finish active recordings, stop listening, and **back up the recording index**
while idle: `~/.local/share/yakker/recordings.json`, or
`$XDG_DATA_HOME/yakker/recordings.json` when configured. Rebuild source checkouts
with `make build`, rerun `./yakker install`, then run:

```sh
omarchy restart shell
```

Schedules, recordings, custom stations, and preferences survive upgrades. Once
v1.8 saves new playback bookmarks, **v1.7.0 cannot read that index**; padding fields
are also incompatible with v1.6.0. Keep the index backup with the previous plugin
for rollback. Plugin backups contain code, not recording metadata.
Restoring an older index hides recordings added since that backup.

## Listen

Click the bar icon, choose a station, and press **Play**. Your last station and
volume are remembered, but playback does not start automatically at login.
Closing the popup leaves audio playing.

| Control | Action |
| --- | --- |
| **Play / Pause** | Start, pause, or resume listening. Paused live radio keeps buffering your place. |
| **Stop** | Disconnect the stream and clear replay history. Playing again starts live. |
| **Rewind / Forward** | Skip 30 seconds when replay is available. |
| **Record** | Open Record now. Background captures continue when listening stops. |
| **Sleep** | Stop listening after a preset or custom timer of 1–240 minutes. |

**Paused · buffering** means the stream remains connected; **Listening stopped**
means it is disconnected. The bar uses compact state icons, with full status and
active recording details in its tooltip. A separate **REC** count marks captures.

![Bar states: live, paused buffering, stopped with a recording, offline, and saved recording paused](docs/yakker-bar-states.png?v=1.8.0)

### Choose a station

Open **Change station**, or right-click the bar icon. Search by station, city,
or country; use **All / Sports / News** with the independent **Favorites** filter.
Save favorites with a heart in the player or picker. Custom stations appear in
All and Favorites.

Choosing a station while playing reconnects to it. While stopped, it only changes
the selection. Long titles scroll without wrapping; reduced-motion mode uses an
ellipsis and a tooltip.

### Keyboard controls

Tab / Shift+Tab moves between controls, Space / Enter activates, and Escape
closes. In the picker, Up / Down browses, Enter selects, and F toggles a favorite.

| Key | Player action |
| --- | --- |
| P | Pause / resume |
| [ / ] | Rewind / forward 30 seconds |
| G | Go live |
| Left / Right | Adjust volume; on tabs, switch sections; on timelines, seek |
| M | Toggle mute |
| R | Retry a stopped stream |

Focused sliders also support Home / End and Page Up / Down. Settings → Listening
includes the shortcut reference.

## Pause and rewind

Choose **Settings → Listening → Replay buffer**:

- **Live only** (default): no replay history is exposed until you pause.
- **5, 15, or 30 minutes:** keep a rolling window for pause and rewind.

Pausing in Live only starts a temporary **15-minute** RAM buffer without
reconnecting. Resume keeps your place; **Go live** returns to the latest audio.
Audio continues arriving while paused, without creating recording files.

Stop, station changes, buffer changes, or a player shutdown clear history.
Reconnecting after a network failure also clears the previous connection's audio.
The selected preset stays saved; temporary pause buffering does not change it.
Live only prepares a bounded packet cache even before you pause. Cache limits
are 32 / 64 / 128 MiB for 5 / 15 / 30 minutes; high-bitrate streams may retain
less time. If your paused position expires, it moves to the oldest available
audio and stays paused.

## Scheduled recordings

Choose **Record** for an immediate capture, or **Schedules → New schedule** for
a one-time or weekly show. Select the station, times, and timezone, then review
the next capture window. An end time before the start means the following day.

**Start early** and **End late** add up to 10 minutes on either side. New schedules
suggest 30 seconds early and one minute late. Edits affect future captures;
an active capture keeps its original settings and has its own **Stop capture**.

### Library and recovered shows

Open **Library** to search, play, resume, or delete recordings. **Listen** provides
the full seek bar, playback speed controls (0.75×–2×), and **Return to live**.
Playback position is saved between sessions; deletion requires confirmation.

Recovered parts from one scheduled occurrence share a show row. Expand **Parts**
for individual captures, recovery notes, and interruption markers. **Resume**
opens the last-played unfinished part, or selects the next part after completion.
Parts play separately: there is no automatic advance or seamless joining.
Gaps remain explicit, and missing audio cannot be reconstructed.

<table>
  <thead>
    <tr>
      <th>Recovered show parts</th>
      <th>Saved-show playback</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td valign="top" align="center"><a href="docs/yakker-recording-parts.png?v=1.8.0"><img src="docs/yakker-recording-parts.png?v=1.8.0" alt="One recovered show with chronological parts, interruption markers, and Resume for part two" width="300"></a></td>
      <td valign="top" align="center"><a href="docs/yakker-recording-player.png?v=1.8.0"><img src="docs/yakker-recording-player.png?v=1.8.0" alt="Saved recording with resume, playback speed, sleep timer, and seek controls" width="300"></a></td>
    </tr>
  </tbody>
</table>

### Recording limits and storage

- **Up to three captures at once**, including while listening to another station.
- **Up to 12 hours per show**, saved as mono Opus at 24 kbit/s VBR—about 11 MB/hour.
- **The computer must be awake with the widget enabled.** There is no wake timer
  or separate background recording service. Shell restarts and disabling the last
  widget interrupt captures; retained audio may be partial, with a linked
  remainder if the original capture window is still open when Yakker returns.
- **Stream failures can retry twice** within the remaining capture window.
  Broadcaster buffering affects duration and timing; exact program boundaries
  are not guaranteed, even with padding.
- **Storage defaults:** `~/Music/Yakker`, a 5 GiB library cap, and a 1 GiB free-space
  reserve. Existing recordings are preserved when full; delete files to make room.

Change the folder or cap under **Settings → Storage** and choose **Save storage**.
Folder changes apply to future recordings; existing files stay at their saved
locations. Schedules, recording settings, and the index live separately at
`~/.local/share/yakker/recordings.json` (under `$XDG_DATA_HOME` when set).
Deleting a schedule does not delete saved recordings.

## Stations

The bundled catalogue has **24 sports stations and 13 news/public-radio stations**.
Public radio also carries interviews, culture, and other scheduled programming.
Availability and regional restrictions depend on the broadcaster.

| Market | Sports | News and public radio |
| --- | --- | --- |
| Atlanta, US | 92.9 The Game | — |
| Boston, US | 98.5 The Sports Hub; WEEI 93.7 | WBZ NewsRadio 1030; WBUR 90.9 |
| Chicago, US | 104.3 The Score | WBBM Newsradio |
| Cleveland, US | 92.3 The Fan | — |
| Columbus, US | 97.1 The Fan | — |
| Dallas–Fort Worth, US | 105.3 The Fan | — |
| Denver, US | 104.3 The Fan | CPR News |
| Detroit, US | 97.1 The Ticket | WWJ Newsradio 950 |
| Los Angeles, US | AM 570 LA Sports | KNX News 1070; LAist 89.3 |
| Minneapolis, US | KFAN 100.3 | MPR News |
| New York, US | ESPN New York 880; WFAN 101.9 / 660 | 1010 WINS / 92.3 FM; WNYC 93.9 |
| Philadelphia, US | SportsRadio 94WIP | KYW Newsradio |
| Pittsburgh, US | 93.7 The Fan | — |
| San Diego, US | 97.3 The Fan | KPBS 89.5 |
| Seattle, US | Seattle Sports 710 | KUOW 94.9 |
| Montreal, Canada | TSN 690 | — |
| Toronto, Canada | Sportsnet 590 The FAN; TSN 1050 | — |
| London, UK | BBC Radio 5 Live; talkSPORT; talkSPORT 2 | — |
| Dublin, Ireland | Off The Ball | — |

For station IDs, use `./yakker listen --list-stations` or see
[stations.json](stations.json).

## Settings and stations

| Tab | Settings |
| --- | --- |
| **Listening** | Replay buffer and keyboard shortcuts. |
| **Storage** | Recording folder and library cap; Save / Reset applies to this tab. |
| **Alerts** | Recording alerts, enabled by default; start notifications are off by default. Changes apply immediately. |
| **Stations** | Add, edit, or delete custom stations using a direct HTTP(S) audio URL. |

City, country, and website are optional for custom stations. They are saved in
`~/.config/yakker/stations.json` (under `$XDG_CONFIG_HOME` when set), outside the
plugin. Widget preferences and position live in `~/.config/omarchy/shell.json`.
Custom stations are also available in the default terminal catalogue.

### Media keys and metadata

Media keys are optional: install a trusted [mpv-mpris](https://github.com/hoyon/mpv-mpris)
plugin and set the widget entry's `mprisPlugin` in `shell.json` to its absolute
path, such as `/etc/mpv/scripts/mpris.so`. Nothing is installed automatically.
MPRIS is available while the player runs; after Stop, restart listening in Yakker.
Program titles appear only when supplied by the stream.

## Terminal player

Both terminal modes run independently of the widget and do not run its scheduler:

```sh
./yakker tui                              # Choose a station interactively
./yakker tui --station wbur --buffer 15
./yakker listen --station weei-fm --volume 60
./yakker listen --list-stations
```

The terminal player remembers its own last station, separately from the widget.
Use Up / Down to browse, Enter to tune, Space to play/stop, P to pause/resume,
[ / ] to skip, G for live, and Q to quit. Press **?** for the complete key list.

### Standalone CLI

With `listen`, type commands such as `pause`, `play`, `back 30`, `live`,
`volume 40`, `status`, or `quit`, then press Enter. Ctrl+C or EOF also exits.
Both modes accept `--url` for a direct stream and `--stations` for an alternate
catalogue. See `./yakker tui --help` or `./yakker listen --help` for all options.

## Troubleshooting

- **No sound:** check Yakker's volume/mute and your system output. Playback status
  does not guarantee sound is reaching the speakers.
- **Cannot connect:** check network access or try another station. Automatic
  retries are bounded; use **Retry** afterward. Broadcaster outages and regional
  restrictions can apply.
- **Missing widget:** run `omarchy plugin list --json`, then
  `omarchy plugin enable io.github.joega.yakker`. After a controller upgrade,
  stop listening and run `omarchy restart shell`.
- **Recordings unavailable:** check FFmpeg/libopus, ffprobe, and the destination's
  free space. If the index is malformed, preserve it before repairing it; ordinary
  listening remains available.
- **Need status or logs:** run `omarchy-shell io.github.joega.yakker status` or
  `qs log -n -p "$OMARCHY_PATH/shell" --tail 100`.

## Disable and remove

```sh
omarchy plugin disable io.github.joega.yakker
omarchy plugin remove io.github.joega.yakker --yes
```

Disabling the last widget stops listening and interrupts captures. Removal also
deletes the installed plugin; audio files, schedules, custom stations, and the
source checkout remain.

## Build checks

From a source checkout:

```sh
make check
YAKKER_TEST_REAL_MPV=1 make check
make release TARGET_ARCH=amd64     # Or arm64; archives and checksums go to dist/
```

Checks cover formatting, vet, module verification, race tests, and optional local
mpv integration. For deeper work, see the
[timing audit](https://github.com/joega/yakker/blob/main/tools/recording-audit/README.md),
[quality comparison](https://github.com/joega/yakker/blob/main/tools/recording-quality/README.md),
[scheduled capture audit](https://github.com/joega/yakker/blob/main/tools/scheduled-recordings-audit.md),
[recovery audit](https://github.com/joega/yakker/blob/main/tools/recording-recovery-audit.md),
and [native UI / screenshot guide](docs/screenshots.md).

## Privacy and licensing

No analytics or accounts. Playback and due recording schedules connect to the
chosen broadcaster and its stream providers. Artwork and station configuration
are bundled locally; preferences, custom stations, and recordings stay on your
machine.

Code is [MIT licensed](LICENSE). Broadcaster artwork and marks belong to their
owners and are excluded from the code license; see [attribution](assets/README.md).
Compiled archives include dependency notices. Yakker is unaffiliated with the
broadcasters.

Built something with Yakker? Credit is appreciated, and we'd love a link in an
issue; attribution is optional under the MIT license.
