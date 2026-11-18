#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Edit Last Capture
# @raycast.mode silent
# @raycast.packageName TextGrabber

# Optional parameters:
# @raycast.icon 🔤
# @raycast.description Reopen the last capture in the editor

open -g "textgrabber://edit-last"
