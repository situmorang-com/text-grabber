#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Capture Text
# @raycast.mode silent
# @raycast.packageName TextGrabber

# Optional parameters:
# @raycast.icon 🔤
# @raycast.description Select an area of the screen and copy its text

open -g "textgrabber://capture"
