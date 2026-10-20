#!/bin/bash
# Builds dist/Utter.app and dist/Utter.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP=Utter
DIST=dist
BUNDLE="$DIST/$APP.app"

echo "→ Compiling (universal: Apple Silicon + Intel)"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release/$APP"

echo "→ Making icon"
# Put your own square image at Resources/AppIcon.png to use it as the app icon.
CUSTOM=Resources/AppIcon.png
ICONSET=.build/AppIcon.iconset
if [ ! -f .build/AppIcon.icns ] || [ scripts/make-icon.swift -nt .build/AppIcon.icns ] || [ build.sh -nt .build/AppIcon.icns ] \
   || { [ -f "$CUSTOM" ] && [ "$CUSTOM" -nt .build/AppIcon.icns ]; } \
   || { [ ! -f "$CUSTOM" ] && [ -f .build/icon-custom-used ]; }; then
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  if [ -f "$CUSTOM" ]; then
    echo "  using $CUSTOM"
    swift scripts/make-icon.swift .build/icon-1024.png "$CUSTOM"
    touch .build/icon-custom-used
  else
    swift scripts/make-icon.swift .build/icon-1024.png
    rm -f .build/icon-custom-used
  fi
  for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
fi

echo "→ Assembling $BUNDLE"
rm -rf "$DIST" && mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp .build/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$BUNDLE"

echo "→ Making DMG"
STAGE=$(mktemp -d)
cp -R "$BUNDLE" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP.dmg" >/dev/null
rm -rf "$STAGE"

echo "✓ Done: $DIST/$APP.dmg"
