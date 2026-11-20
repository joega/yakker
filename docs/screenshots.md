# README screenshots

Refresh all eight screenshots from the repository root:

```sh
bash tools/capture-readme.sh
```

Pass another destination to review captures before replacing the README assets:

```sh
bash tools/capture-readme.sh /tmp/yakker-readme-preview
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

All eight screenshots use **Catppuccin Latte** for a consistent presentation.
Yakker follows the user's active Omarchy theme; the screenshots are a shared
visual reference, not a separate theme setting in Yakker.

The images render the checkout's actual `Panel.qml`, `RecordingsView.qml`, and
shared native controls. A headless wrapper reproduces the popup card's border,
padding, and content sizing without opening a desktop layer-shell surface.
The screenshot process supplies illustrative station, playback, schedule, and
library state. Show labels, dates, file sizes, and the `/home/demo` storage path
are examples. It does not start the controller, connect to broadcasters, create
recordings, or change the installed plugin or user settings.

These images document appearance. For real controller, recording playback,
keyboard, and lifecycle checks, use `tools/test-recordings-ui.py` and the checks
described in [recordings validation](recordings-validation.md).
