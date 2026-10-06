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

# Build provenance for the About window: the channel, commit, branch and dirty state.
# A tag build (CLAUDEWATCH_VERSION set, as the release job does) is the release
# channel and records nothing about the repository; CI is "ci"; anything else "dev".
if [ -z "${BUILD_CHANNEL:-}" ]; then
  if [ -n "${CLAUDEWATCH_VERSION:-}" ]; then BUILD_CHANNEL=release
  elif [ -n "${CI:-}" ]; then BUILD_CHANNEL=ci
  else BUILD_CHANNEL=dev
  fi
fi
export BUILD_CHANNEL
BUILD_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
BUILD_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
BUILD_DIRTY_FILES="$( (git status --porcelain 2>/dev/null || true) | wc -l | tr -d ' ')"
BUILD_DIRTY=NO
[ "${BUILD_DIRTY_FILES:-0}" -gt 0 ] && BUILD_DIRTY=YES
BUILD_TAGGED=NO
git describe --tags --exact-match HEAD >/dev/null 2>&1 && BUILD_TAGGED=YES
if [ "$BUILD_CHANNEL" = release ]; then
  BUILD_SHA=""
  BUILD_BRANCH=""
fi

# Refresh the shared Settings, menu and About code, or verify the committed copy.
python3 .project/mac_surfaces.py sync

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

# App icon.
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# The in-app manual (Help ▸ ClaudeWatch Help): Markdown pages bundled with the app so
# they always match the version that ships.
if [ -d Resources/Manual ]; then
  rm -rf "$APP/Contents/Resources/Manual"
  cp -R Resources/Manual "$APP/Contents/Resources/Manual"
fi

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
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSHumanReadableCopyright</key>   <string>© 2026 Adam Kostarelas</string>
    <key>SUFeedURL</key>                  <string>${SU_FEED_URL}</string>
    <key>SUEnableAutomaticChecks</key>    <false/>
    ${SU_KEY_LINE}
    <key>BuildChannel</key>               <string>${BUILD_CHANNEL}</string>
    <key>BuildSHA</key>                   <string>${BUILD_SHA}</string>
    <key>BuildBranch</key>                <string>${BUILD_BRANCH}</string>
    <key>BuildDirty</key>                 <string>${BUILD_DIRTY}</string>
    <key>BuildDirtyFiles</key>            <string>${BUILD_DIRTY_FILES}</string>
    <key>BuildTagged</key>                <string>${BUILD_TAGGED}</string>
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
