# README screenshots

Refresh the eighteen player/settings screenshots and the two bar previews from
the repository root:

```sh
bash tools/capture-readme.sh
bash tools/capture-bar-readme.sh
```

Pass another destination to review captures before replacing the README assets:

```sh
bash tools/capture-readme.sh /tmp/yakker-readme-preview
bash tools/capture-bar-readme.sh /tmp/yakker-readme-preview
```

The renderer needs jq, Quickshell, Qt Quick / QtTest, the installed Omarchy `qs.Ui`
and `qs.Commons` modules, and JetBrainsMono Nerd Font. It reads the theme mapping
from `tools/readme/themes.json` and uses each packaged theme’s `colors.toml`, the
official stock shell template, and any packaged shell overrides in temporary
staging. The palette and style are applied in an isolated native QML process;
font, scale, and layout stay consistent across captures. It does not switch the
desktop theme or modify desktop configuration. Images use a two-times display
scale for sharpness. Review every image after a capture, especially dropdown
placement, text wrapping, and long editor screens.

The eighteen player/settings screenshots use **Catppuccin Latte** and varied
stations for a consistent presentation. Player text uses Adwaita Sans; shell
labels use JetBrainsMono Nerd Font.
Yakker follows the user's active Omarchy theme; the screenshots are a shared
visual reference, not a separate theme setting in Yakker.

The images render the checkout's actual `Panel.qml`, `RecordingsView.qml`, and
shared native controls. A headless wrapper reproduces the popup card's border,
padding, and content sizing without opening a desktop layer-shell surface.
The screenshot process supplies illustrative station, playback, schedule, and
library state. Show labels, dates, file sizes, and the `/home/demo` storage path
are examples. It does not start the controller, connect to broadcasters, create
recordings, or change the installed plugin or user settings.

The two bar previews come from the native UI regression fixtures, using their
isolated dark palette. `capture-bar-readme.sh` needs the native test dependencies
listed in the README plus ImageMagick (`magick`) and Fontconfig (`fc-match`). It
runs the full native UI test with local audio and no audible output, then arranges
the captured widgets and tooltips into two sheets. Widget pixels keep their native
size; captions explain states without adding text to the bar itself. The tooltip
sheet uses the production plain-text string and matching native tooltip surface.
No desktop screenshots or private listening/recording data are used.

Review all twenty images after capture. Keep the selected station and recording
source artwork consistent within each example, and vary stations across examples.
Schedule names must match the bundled catalogue. Dates, durations, and recording
states should be internally consistent; avoid retaining a previous example's
buffering or timer state in an unrelated view.

The 1.7 gallery shows padded schedule windows and a recovered partial recording.
The current player keeps favorites behind a compact dropdown beside the station
picker, so the saved-station list does not change the player's vertical layout.
Its unknown capture end is deliberate: a forced controller exit cannot supply a
precise end timestamp. The editor's preview timer is paused only in the temporary
screenshot wrapper, so illustrative preview text is not replaced by a disconnected
controller message. Production controls and their layout are unchanged.

These images document appearance. For real controller, recording playback,
keyboard, and lifecycle checks, use `tools/test-recordings-ui.py` and the checks
described in the README’s Build checks section. Internal sprint plans and
validation notes stay local under the ignored `build/planning/` directory.
