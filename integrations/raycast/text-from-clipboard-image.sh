#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Text from Clipboard Image
# @raycast.mode silent
# @raycast.packageName TextGrabber

# Optional parameters:
# @raycast.icon 🔤
# @raycast.description Copy the text in the image on the clipboard

open -g "textgrabber://clipboard"
