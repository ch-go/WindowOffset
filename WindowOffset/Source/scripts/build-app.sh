#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/../WindowOffset.app"
swift build --package-path "$PROJECT_DIR" -c release --product WindowOffset
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
# Explicit permissions also repair an existing non-executable app binary.
install -m 755 "$BIN_DIR/WindowOffset" "$APP_DIR/Contents/MacOS/WindowOffset"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
# Local ad-hoc signature, no developer account or network service required.
codesign --force --sign - --identifier local.windowoffset.app "$APP_DIR"
codesign --verify --strict "$APP_DIR"
if [[ ! -x "$APP_DIR/Contents/MacOS/WindowOffset" ]]; then
    echo "Build failed: WindowOffset is not executable" >&2
    exit 1
fi
echo "Built: $APP_DIR"
