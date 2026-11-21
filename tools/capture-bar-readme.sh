#!/usr/bin/env bash
# Refresh the bar examples from the real native UI regression fixtures.
# The test helper uses isolated settings, local recordings and silent audio.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=${1:-"$project_dir/docs"}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
command -v magick >/dev/null
command -v fc-match >/dev/null
capture_dir=$(mktemp -d /tmp/yakker-bar-readme-XXXXXX)
trap 'rm -rf -- "$capture_dir"' EXIT
if ! python3 "$project_dir/tools/test-recordings-ui.py" --output "$capture_dir/frames" > "$capture_dir/test.log" 2>&1; then
  cat "$capture_dir/test.log"
  exit 1
fi
font_path=$(fc-match -f '%{file}' 'Adwaita Sans')
frames=(bar-live bar-paused-buffering bar-stopped-recording bar-error bar-paused-recording)
labels=('Live' 'Paused · buffering' 'Stopped · recording' 'Connection error' 'Saved recording paused')
rows=()
for index in "${!frames[@]}"; do
  row="$capture_dir/row-$index.png"
  # Keep each widget at its captured size; captions explain the examples only.
  magick -size 360x54 xc:'#101315' -font "$font_path" -pointsize 14 \
    -fill '#cdd0d1' -gravity West -annotate +14+0 "${labels[$index]}" \
    "$capture_dir/frames/${frames[$index]}.png" -gravity East -geometry +16+0 \
    -composite "$row"
  rows+=("$row")
done
magick "${rows[@]}" -append "$output_dir/yakker-bar-states.png"
magick montage "$capture_dir/frames/tooltip-live.png" \
  "$capture_dir/frames/tooltip-paused-buffering.png" \
  "$capture_dir/frames/tooltip-stopped-recordings.png" \
  "$capture_dir/frames/tooltip-paused-recording.png" \
  -background '#101315' -tile 2x2 -geometry +12+12 -gravity Center \
  "$output_dir/yakker-bar-tooltips.png"
printf 'Rendered bar states and tooltip previews in %s\n' "$output_dir"
