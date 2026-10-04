# Contributing to ClaudeWatch

## Requirements

macOS 13 or later and a Swift 5.9 toolchain (Xcode or the Command Line Tools). There are no
other prerequisites — the only package dependency is
[Sparkle](https://github.com/sparkle-project/Sparkle), which Swift Package Manager fetches
for you.

## Project layout

```
Sources/ClaudeWatchCore/   # pure, headless logic — unit-tested
  EventKind, CommandEvent, TranscriptParser, CodexTranscriptParser,
  EventScanner, TranscriptStore, TranscriptWatcher, ScanDemand,
  TranscriptSource, SessionTracker, SessionStatus, LineMarkers, ISOTimestamp,
  TranscriptHTMLRenderer, RelativeTime,
  NotificationRule, NotificationEngine, SettingsStore, MenuBarInsertion,
  Keychain
Sources/ClaudeWatch/       # the SwiftUI menu-bar app
  ClaudeWatchApp, main, Actions, Updater, Highlighter,
  SourceAvailability, SettingsWindow, DumpRunner, RenderTest
  Views/                   # MenuContentView, CommandRowView,
                           # ActiveSessionsView, EmptySourcesView, SettingsView
Tests/ClaudeWatchTests/    # XCTest coverage for the Core
Tools/make_icon.swift      # regenerates Resources/AppIcon.icns
```

`ClaudeWatchCore` is deliberately dependency-free and UI-free so the parsing, scanning and
rendering can be tested without launching an app. Only the `ClaudeWatch` executable target
links Sparkle.

## Commands

```sh
swift test            # the Core test suite
swift build -c release
./build.sh release    # assembles ClaudeWatch.app around the release binary
```

There is also a [justfile](justfile), if you have [just](https://just.systems) installed:

```sh
just test
just build            # swift build -c release && ./build.sh release
just run              # build, then open the app
just clean            # rm -rf .build ClaudeWatch.app
```

`build.sh` takes the configuration as its first argument (default `release`), writes the
`Info.plist` — including the bundle version, the `LSUIElement` flag that keeps it out of the
Dock, and the Sparkle feed URL — and, when run outside CI, relaunches the freshly built app
so the menu bar picks it up.

## Headless inspection

The same binary can dump the latest parsed actions as text, which is the quickest way to
check parsing without the UI:

```sh
swift run ClaudeWatch --dump
```

`--render-test` validates the transcript-to-HTML renderer in the same way. Notifications
no-op in both modes, because there is no app bundle to post them from.

## What CI checks

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs on macOS on every push to
`main`, every pull request against `main`, and every `v*` tag. The `build-test` job prints
the toolchain versions, runs `swift build -c release`, `swift test`, and `./build.sh
release`, then uploads the unsigned `.app` as a zipped artifact.

## Releasing

Pushing a `v*` tag additionally runs the `release` job, which signs the app with a Developer
ID identity, notarises and staples it, publishes a Sparkle appcast to the `gh-pages` branch,
and creates a GitHub Release with `ClaudeWatch.zip` and its SHA-256. The signing,
notarisation and Sparkle-signing steps each degrade gracefully with a warning when their
secrets (`MACOS_CERTIFICATE`, `MACOS_SIGN_IDENTITY`, `AC_API_KEY_P8`,
`SPARKLE_ED_PRIVATE_KEY`) are absent, so a tag pushed without them still produces an
unsigned release rather than failing.

No release has been published yet, so this path has not run against a real tag.
