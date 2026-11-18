#!/bin/bash
# Runs a textgrabber:// action in the installed app and prints the log it writes: one call in place of
# open, sleep and cat. Waits for the log to be rewritten, not for a guessed time.
#   scripts/drive.sh "probe?rect=100,100,600,300"           # read a screen area into the log, clipboard untouched
#   scripts/drive.sh "snapshot?window=setup"                # draw a window to a PNG; works while the screen is locked
#   scripts/drive.sh "selftest-scrolling?path=/abs/page.png" 90
# Actions that only open a window write no log: use snapshot?window=… to check those.
set -euo pipefail
ACTION="${1:?usage: drive.sh <action[?query]> [timeout seconds, default 30]}"
TIMEOUT="${2:-30}"
LOG="$HOME/Library/Logs/TextGrabber/last-capture.txt"

stamp() { stat -f '%i %Fm' "$LOG" 2>/dev/null || echo none; }   # the log is replaced atomically: new inode each write

if ! pgrep -x TextGrabber >/dev/null; then
  open -g /Applications/TextGrabber.app
  for ((i = 0; i < 40; i++)); do pgrep -x TextGrabber >/dev/null && break; sleep 0.25; done
  sleep 1   # let it register its URL handler
fi
before=$(stamp)
open -g "textgrabber://${ACTION#textgrabber://}"
for ((i = 0; i < TIMEOUT * 4; i++)); do
  if [ "$(stamp)" != "$before" ]; then cat "$LOG"; exit 0; fi
  sleep 0.25
done
echo "drive.sh: no log within ${TIMEOUT}s for \"$ACTION\"."
echo "TextGrabber running: $(pgrep -x TextGrabber >/dev/null && echo yes || echo no). Screen state: run probe.sh from the macos-app-build skill."
exit 1
