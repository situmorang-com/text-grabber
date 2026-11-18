#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Capture Text and Edit
# @raycast.mode silent
# @raycast.packageName TextGrabber

# Optional parameters:
# @raycast.icon 🔤
# @raycast.description Select an area and open the text in the editor

open -g "textgrabber://capture-edit"
