#!/bin/bash
# Builds TextGrabber.app and installs it to /Applications (pass --no-install to leave it in build/). Signed with the identity from scripts/setup-signing.sh (or SIGN_IDENTITY, or ad hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
APP="build/TextGrabber.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TextGrabber"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TextGrabber"

# Icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make-icon.swift build/icon-1024.png
for size in 16 32 128 256 512; do
  sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TextGrabber</string>
  <key>CFBundleDisplayName</key><string>TextGrabber</string>
  <key>CFBundleIdentifier</key><string>app.textgrabber.TextGrabber</string>
  <key>CFBundleExecutable</key><string>TextGrabber</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>app.textgrabber.TextGrabber</string>
      <key>CFBundleURLSchemes</key><array><string>textgrabber</string></array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Image or PDF</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>None</string>
      <key>LSItemContentTypes</key>
      <array><string>public.image</string><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign with the local identity from scripts/setup-signing.sh when it exists, so macOS permissions survive rebuilds.
KEYCHAIN="$HOME/Library/Keychains/textgrabber-signing.keychain-db"
SECRET="$HOME/.config/textgrabber/signing-keychain-password"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --identifier app.textgrabber.TextGrabber "$APP"
elif [ -f "$KEYCHAIN" ] && [ -f "$SECRET" ]; then
  security unlock-keychain -p "$(cat "$SECRET")" "$KEYCHAIN"
  IDENTITY=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/TextGrabber Local Signing/{print $2; exit}')
  codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier app.textgrabber.TextGrabber "$APP"
else
  echo "No signing identity: signing ad hoc. macOS will ask for permissions again after each rebuild."
  echo "Run scripts/setup-signing.sh once to avoid that."
  codesign --force --sign - --identifier app.textgrabber.TextGrabber "$APP"
fi
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/TextGrabber"))"

# Install: one copy only, in /Applications, so Spotlight, the shortcut and open-at-login all use the same app.
if [ "${1:-}" != "--no-install" ]; then
  INSTALLED="/Applications/TextGrabber.app"
  pkill -x TextGrabber 2>/dev/null && sleep 1 || true
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  rm -rf "$APP"
  open -g "$INSTALLED"
  echo "Installed and started $INSTALLED"
fi
