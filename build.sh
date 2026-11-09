#!/bin/bash
# Compila Acta.app sin abrir Xcode. Requiere Xcode 26 (o sus Command Line Tools) en un Mac con Apple Silicon.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Acta.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

xcrun --sdk macosx swiftc \
  -O -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -parse-as-library \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Acta"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

echo "Listo: $APP"
echo "Para instalar:  cp -R \"$APP\" /Applications/ && open /Applications/Acta.app"
