#!/bin/bash
# Screenshots of the real app for the README: the confirmation, the code confirmation, the editor and Settings,
# fed with the demo scenes (scenes.swift), never with anything on the user's screen. Needs the installed app
# and Screen Recording for this terminal. The clipboard and history are left as they were.
#   scripts/readme-media/capture-ui.sh <scenes folder>
set -euo pipefail
cd "$(dirname "$0")/../.."
SRC="$(cd "${1:-build/readme-media}" && pwd)"
UI="$SRC/ui"; mkdir -p "$UI"
HERE=scripts/readme-media
DOMAIN=app.textgrabber.TextGrabber

shot() {   # shot <title substring or ""> <out.png>: the window with its shadow, as macOS draws it
  local id
  for _ in 1 2 3 4 5 6 7 8; do id=$(swift $HERE/window-id.swift "$1") && break; sleep 0.25; done
  /usr/sbin/screencapture -x -l "$id" "$2" && echo "  $(basename "$2")"
}

# Settings first, while history is still on as the user has it.
scripts/drive.sh "snapshot?window=settings&keep=1" >/dev/null
shot "settings" "$UI/settings.png"; open -g "textgrabber://hide?window=settings"

swift $HERE/clipboard.swift save "$SRC/clipboard-backup.plist" >/dev/null
HISTORY=$(defaults read $DOMAIN keepHistory 2>/dev/null || echo unset)
defaults write $DOMAIN keepHistory -bool false
restore() {
  swift $HERE/clipboard.swift restore "$SRC/clipboard-backup.plist" >/dev/null
  rm -f "$SRC/clipboard-backup.plist"
  if [ "$HISTORY" = unset ]; then defaults delete $DOMAIN keepHistory; else defaults write $DOMAIN keepHistory -bool "$HISTORY"; fi
}
trap restore EXIT

scripts/drive.sh "open?path=$SRC/crop-article.png" >/dev/null
sleep 0.35; shot "" "$UI/confirmation.png"

scripts/drive.sh "snapshot?window=editor&keep=1" >/dev/null
shot "captured text" "$UI/editor.png"; open -g "textgrabber://hide?window=editor"

scripts/drive.sh "open?path=$SRC/crop-poster.png" >/dev/null
sleep 0.45; shot "" "$UI/code-confirmation.png"
