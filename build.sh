#!/bin/bash
# Builds ClaudeWatch and wraps the binary into a menu-bar .app bundle.
#
# Version: pass CLAUDEWATCH_VERSION (e.g. "1.2.0" or "v1.2.0"), otherwise it is
# derived from `git describe`, otherwise it falls back to 0.0.0-dev.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="ClaudeWatch.app"
BUNDLE_ID="io.github.adamxbot.claudewatch"

VERSION="${CLAUDEWATCH_VERSION:-$(git describe --tags --always 2>/dev/null || true)}"
VERSION="${VERSION#v}"                       # strip a leading "v"
VERSION="${VERSION:-0.0.0-dev}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "→ swift build -c $CONFIG  (version $VERSION, build $BUILD_NUMBER)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/ClaudeWatch"
if [[ ! -f "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeWatch"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>ClaudeWatch</string>
    <key>CFBundleDisplayName</key>        <string>ClaudeWatch</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>         <string>ClaudeWatch</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

echo "✓ Built $APP  (v$VERSION)"
echo "  Run it:   open $APP"
echo "  Inspect:  ./$APP/Contents/MacOS/ClaudeWatch --dump"
