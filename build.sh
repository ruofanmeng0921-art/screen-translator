#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$BUILD_DIR/屏幕翻译.app"
SIGNING_MODE="${SIGNING_MODE:-auto}"
if (( $# > 0 )); then
  if (( $# != 2 )) || [[ "$1" != "--signing" ]]; then
    print -u2 -- "Usage: zsh build.sh [--signing auto|local|adhoc]"
    exit 2
  fi
  SIGNING_MODE="$2"
fi
case "$SIGNING_MODE" in
  auto)
    # Never silently replace an existing local identity.
    if [[ -e "$PROJECT_DIR/.signing" ]]; then SIGNING_MODE=local; else SIGNING_MODE=adhoc; fi
    ;;
  local|adhoc) ;;
  *) print -u2 -- "Unknown signing mode: $SIGNING_MODE"; exit 2 ;;
esac
if [[ "$(uname -m)" != arm64 ]]; then
  print -u2 -- "This version requires an Apple Silicon Mac."
  exit 1
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR/ModuleCache"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/apple-logo.svg" "$APP_DIR/Contents/Resources/apple-logo.svg"
xcrun swift -module-cache-path "$BUILD_DIR/ModuleCache" "$PROJECT_DIR/Tools/MakeIcon.swift"   "$PROJECT_DIR/Resources/apple-logo.svg" "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macos26.0   -module-cache-path "$BUILD_DIR/ModuleCache"   -framework AppKit -framework SwiftUI -framework Vision   -framework NaturalLanguage -framework ScreenCaptureKit -framework Translation   "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/ScreenTranslator"
if [[ "$SIGNING_MODE" == local ]]; then
  python3 "$PROJECT_DIR/Tools/SignLocal.py" "$APP_DIR"
else
  codesign --force --sign - --identifier local.silver.screen-translator --timestamp=none "$APP_DIR"
  codesign --verify --deep --strict "$APP_DIR"
  print -- "Ad-hoc build: macOS may ask for screen permission again after a rebuild."
fi
print -r -- "$APP_DIR"
