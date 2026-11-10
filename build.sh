#!/bin/bash
# Compila Acta.app sin abrir Xcode. Requiere Xcode 26 (o sus Command Line Tools) en un Mac con Apple Silicon.
set -euo pipefail
cd "$(dirname "$0")"

# Comprobaciones previas: Acta necesita macOS 26 y el SDK de macOS 26.
OS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
SDK_VER=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "0")
SDK_MAJOR=$(echo "$SDK_VER" | cut -d. -f1)

if [ "$OS_MAJOR" -lt 26 ]; then
  echo "✗ Tu Mac tiene macOS $(sw_vers -productVersion). Acta necesita macOS 26 (Tahoe) o superior."
  exit 1
fi
if [ "$SDK_MAJOR" -lt 26 ]; then
  echo "✗ Tus herramientas de compilación traen el SDK de macOS $SDK_VER y Acta necesita el 26."
  echo "  Reinstálalas con:"
  echo "    sudo rm -rf /Library/Developer/CommandLineTools"
  echo "    xcode-select --install"
  exit 1
fi

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
