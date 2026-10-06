#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/.build/屏幕翻译.app}"
DIST_DIR="$PROJECT_DIR/dist"
if [[ ! -d "$APP_DIR" ]]; then print -u2 -- "Build first: zsh build.sh"; exit 1; fi
codesign --verify --deep --strict "$APP_DIR"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
STEM="ScreenTranslator-$VERSION-macOS-arm64"
mkdir -p "$DIST_DIR"
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp/}screen-translator-release.XXXXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT
# Exclude extended attributes and resource forks from distributable copies.
ditto --norsrc --noextattr "$APP_DIR" "$STAGE_DIR/屏幕翻译.app"
codesign --verify --deep --strict "$STAGE_DIR/屏幕翻译.app"
cp "$PROJECT_DIR/README.md" "$STAGE_DIR/使用说明.md"
cp "$PROJECT_DIR/LICENSE" "$STAGE_DIR/LICENSE"
cp "$PROJECT_DIR/NOTICE" "$STAGE_DIR/NOTICE"
python3 - "$STAGE_DIR" "$DIST_DIR/$STEM.zip" <<'PY'
from pathlib import Path
import sys
import zipfile
stage = Path(sys.argv[1])
# Standard UTF-8 filenames and Unix executable modes, without Mac metadata.
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(stage.rglob("*")):
        archive.write(path, path.relative_to(stage).as_posix())
PY
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "屏幕翻译 $VERSION" -srcfolder "$STAGE_DIR" -format UDZO -ov "$DIST_DIR/$STEM.dmg"
(cd "$DIST_DIR" && shasum -a 256 "$STEM.zip" "$STEM.dmg" > SHA256SUMS.txt)
print -r -- "$DIST_DIR"
