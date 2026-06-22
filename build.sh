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

# Sparkle auto-update: feed URL is fixed; the EdDSA public key is injected at release
# time (see RELEASING.md). Omitted for local dev builds, which simply won't auto-update.
SU_FEED_URL="${SU_FEED_URL:-https://adamxbot.github.io/ClaudeWatch/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}"
SU_KEY_LINE=""
[ -n "$SU_PUBLIC_ED_KEY" ] && SU_KEY_LINE="<key>SUPublicEDKey</key><string>${SU_PUBLIC_ED_KEY}</string>"

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

# Embed Sparkle.framework so the app can self-update.
SPARKLE_FW="$(find .build -type d -path '*Sparkle.xcframework/macos*/Sparkle.framework' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
  echo "→ embedding Sparkle.framework"
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/ClaudeWatch" 2>/dev/null || true
else
  echo "warning: Sparkle.framework not found under .build — auto-update will be unavailable" >&2
fi

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
    <key>SUFeedURL</key>                  <string>${SU_FEED_URL}</string>
    ${SU_KEY_LINE}
</dict>
</plist>
PLIST

echo "✓ Built $APP  (v$VERSION)"

if [ -z "${CI:-}" ]; then
  # Locally, relaunch the freshly-built app. Also stop the pre-rename ClaudeLog app
  # and any previous ClaudeWatch instance so the menu bar shows the new build.
  pkill -x ClaudeLog 2>/dev/null || true
  pkill -x ClaudeWatch 2>/dev/null || true
  echo "→ opening $APP"
  open "$APP"
else
  echo "  Run it:   open $APP"
fi
echo "  Inspect:  ./$APP/Contents/MacOS/ClaudeWatch --dump"
