#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Read QR Code
# @raycast.mode silent
# @raycast.packageName TextGrabber

# Optional parameters:
# @raycast.icon 🔤
# @raycast.description Select an area and copy what its QR code or barcode contains

open -g "textgrabber://read-code"
