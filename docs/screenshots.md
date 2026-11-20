# README screenshots

Refresh all eight screenshots from the repository root:

```sh
bash tools/capture-readme.sh
```

Pass another destination to review captures before replacing the README assets:

```sh
bash tools/capture-readme.sh /tmp/yakker-readme-preview
```

The renderer needs Quickshell, Qt Quick / QtTest, the installed Omarchy `qs.Ui`
and `qs.Commons` modules, and JetBrainsMono Nerd Font. It uses the current theme
and a two-times display scale for sharp images. Review every image after a
capture, especially dropdown placement, text wrapping, and long editor screens.

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
