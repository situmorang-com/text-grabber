#!/bin/bash
# Rebuilds the README media in docs/media: the demo animation and the screenshots. Uses the installed app
# (build it first with scripts/build-app.sh) and needs Screen Recording for this terminal.
#   scripts/readme-media/make.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK=build/readme-media
OUT=docs/media
mkdir -p "$OUT"

swift scripts/readme-media/scenes.swift "$WORK"
# The text the real app reads from the demo selection, shown pasted in the animation.
/Applications/TextGrabber.app/Contents/MacOS/TextGrabber "$WORK/crop-article.png" > "$WORK/article.txt"
scripts/readme-media/capture-ui.sh "$WORK"
swift scripts/readme-media/compose.swift "$WORK"
ffmpeg -loglevel error -y -framerate 15 -i "$WORK/frames/f%04d.png" \
  -vf "split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  -loop 0 "$OUT/demo.gif"
for name in confirmation code-confirmation editor settings; do cp "$WORK/ui/$name.png" "$OUT/$name.png"; done
swift scripts/make-icon.swift "$WORK/icon-1024.png"
sips -z 256 256 "$WORK/icon-1024.png" --out "$OUT/icon.png" >/dev/null
ls -la "$OUT"
