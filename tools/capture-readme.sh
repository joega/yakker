#!/usr/bin/env bash
# Render the checkout's native QML with sample state; no installed plugin changes,
# controller, broadcaster connections, or real recording files are involved.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:-"$project_dir/docs"}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
omarchy_dir=${OMARCHY_PATH:-/usr/share/omarchy}
shell_dir=$omarchy_dir/shell
capture_dir=$(mktemp -d /tmp/yakker-readme-XXXXXX)
trap 'rm -rf -- "$capture_dir"' EXIT
mkdir -p "$capture_dir/imports/qs" "$capture_dir/plugin" "$capture_dir/runtime" "$capture_dir/config" "$capture_dir/data"
chmod 700 "$capture_dir/runtime"
# Reuse the installed renderer, pointing every output and template lookup at
# this temporary staging tree. Only shell.toml is generated, without applying
# a theme or touching the user's current/next-theme directories.
mkdir -p "$capture_dir/templates" "$capture_dir/themes"
cp "$omarchy_dir/default/themed/shell.toml.tpl" "$capture_dir/templates/"
awk '
  /^TEMPLATES_DIR=/ { print "TEMPLATES_DIR=\"$YAKKER_CAPTURE_TEMPLATES\""; next }
  /^USER_TEMPLATES_DIR=/ { print "USER_TEMPLATES_DIR=\"$YAKKER_CAPTURE_EMPTY_TEMPLATES\""; next }
  /^NEXT_THEME_DIR=/ { print "NEXT_THEME_DIR=\"$YAKKER_CAPTURE_THEME_DIR\""; next }
  { print }
' "$omarchy_dir/bin/omarchy-theme-set-templates" > "$capture_dir/render-theme.sh"
cp "$project_dir/tools/readme/themes.json" "$capture_dir/themes.json"
while IFS= read -r theme; do
  theme_dir=$omarchy_dir/themes/$theme
  staged_theme=$capture_dir/themes/$theme
  mkdir -p "$staged_theme"
  cp "$theme_dir/colors.toml" "$staged_theme/"
  for override in "$theme_dir"/shell*.toml; do
    if [[ -f $override ]]; then cp "$override" "$staged_theme/"; fi
  done
  env OMARCHY_PATH="$omarchy_dir" XDG_STATE_HOME="$capture_dir/state" \
    YAKKER_CAPTURE_TEMPLATES="$capture_dir/templates" \
    YAKKER_CAPTURE_EMPTY_TEMPLATES="$capture_dir/no-user-templates" \
    YAKKER_CAPTURE_THEME_DIR="$staged_theme" \
    bash "$capture_dir/render-theme.sh"
  test -s "$staged_theme/shell.toml"
  if rg -q '\{\{' "$staged_theme/shell.toml"; then
    printf 'Unresolved shell template for %s\n' "$theme" >&2
    exit 1
  fi
done < <(jq -r '[.[]] | unique[]' "$capture_dir/themes.json")
cp -r "$shell_dir/Ui" "$capture_dir/imports/qs/Ui"
cp "$project_dir/tools/readme/KeyboardPanel.qml" "$capture_dir/imports/qs/Ui/KeyboardPanel.qml"
ln -s "$shell_dir/Commons" "$capture_dir/imports/qs/Commons"
ln -s "$shell_dir/services" "$capture_dir/imports/qs/services"
cp "$project_dir"/{Panel.qml,RecordingsView.qml,RadioService.qml,RecordingNotices.js,StationLogo.qml,FocusButton.qml,FocusIcon.qml,StationPicker.qml,MarqueeText.qml,StateCard.qml,FocusTextField.qml,FocusDropdown.qml,FocusSlider.qml,qmldir,stations.json} "$capture_dir/plugin/"
ln -s "$project_dir/assets" "$capture_dir/plugin/assets"
awk '
  /property var anchorItem: null/ {
    print "  property alias screenshotPanel: panel"
    print "  property alias screenshotScroller: scroller"
    print "  property alias screenshotPicker: stationPicker"
    print "  property alias screenshotView: recordingsView"
    print "  property alias screenshotSleep: sleepPopup"
  }
  { print }
' "$project_dir/Panel.qml" > "$capture_dir/plugin/Panel.qml"
awk '/required property var radio/ { print "  property alias screenshotSearch: searchField"; print "  property alias screenshotPreviewDelay: previewDelay" } { print }' "$project_dir/RecordingsView.qml" > "$capture_dir/plugin/RecordingsView.qml"
awk '/property string value:/ { print "  property alias screenshotSearch: search" } { print }' "$project_dir/StationPicker.qml" > "$capture_dir/plugin/StationPicker.qml"
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
printf 'Rendered eighteen README screenshots in %s\n' "$output_dir"
