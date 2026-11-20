#!/usr/bin/env bash
# Render the checkout's native QML with sample state; no installed plugin changes,
# controller, broadcaster connections, or real recording files are involved.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:-"$project_dir/docs"}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
shell_dir=${OMARCHY_PATH:-/usr/share/omarchy}/shell
capture_dir=$(mktemp -d /tmp/yakker-readme-XXXXXX)
trap 'rm -rf -- "$capture_dir"' EXIT
mkdir -p "$capture_dir/imports/qs" "$capture_dir/plugin" "$capture_dir/runtime" "$capture_dir/config" "$capture_dir/data"
chmod 700 "$capture_dir/runtime"
cp -r "$shell_dir/Ui" "$capture_dir/imports/qs/Ui"
cp "$project_dir/tools/readme/KeyboardPanel.qml" "$capture_dir/imports/qs/Ui/KeyboardPanel.qml"
ln -s "$shell_dir/Commons" "$capture_dir/imports/qs/Commons"
ln -s "$shell_dir/services" "$capture_dir/imports/qs/services"
cp "$project_dir"/{Panel.qml,RecordingsView.qml,RadioService.qml,StationLogo.qml,qmldir,stations.json} "$capture_dir/plugin/"
ln -s "$project_dir/assets" "$capture_dir/plugin/assets"
awk '
  /property var anchorItem: null/ {
    print "  property alias screenshotPanel: panel"
    print "  property alias screenshotScroller: scroller"
    print "  property alias screenshotPicker: stationPicker"
    print "  property alias screenshotView: recordingsView"
  }
  { print }
' "$project_dir/Panel.qml" > "$capture_dir/plugin/Panel.qml"
cp "$project_dir/tools/readme/gallery.qml" "$capture_dir/shell.qml"
if ! timeout 60s env -u QT_QPA_PLATFORMTHEME \
  XDG_RUNTIME_DIR="$capture_dir/runtime" XDG_CONFIG_HOME="$capture_dir/config" XDG_DATA_HOME="$capture_dir/data" \
  QML_IMPORT_PATH="$capture_dir/imports" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_SCALE_FACTOR=2 \
  QML_XHR_ALLOW_FILE_READ=1 YAKKER_SCREENSHOT_DIR="$output_dir" \
  quickshell -p "$capture_dir/shell.qml" > "$capture_dir/render.log" 2>&1; then
  cat "$capture_dir/render.log"
  exit 1
fi
if ! rg -q 'YAKKER_README_SCREENSHOTS_PASS' "$capture_dir/render.log"; then
  cat "$capture_dir/render.log"
  exit 1
fi
printf 'Rendered README screenshots in %s\n' "$output_dir"
