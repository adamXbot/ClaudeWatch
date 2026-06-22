# ClaudeWatch

A lightweight macOS **menu-bar app that shows the latest system-touching actions
[Claude Code](https://claude.com/claude-code) performs on your machine** — shell
commands, file writes/edits, and network fetches — so you can see at a glance what the
AI is actually doing.

Each entry links back to the thread that issued it: open the full conversation in your
browser (scrolled to the exact command), or resume that session in Claude Code.

It is a **read-only history tool**. It only ever reads your local Claude Code transcripts
under `~/.claude/projects` and makes **no network connections**.

## What it shows

| Tool | Shown as |
|------|----------|
| `Bash` | the shell command + its description |
| `Write` | the file path written + size |
| `Edit` / `MultiEdit` | the file path edited |
| `NotebookEdit` | the notebook path + edit mode |
| `WebFetch` | the URL fetched |
| `WebSearch` | the search query |

Read-only tools (Read/Grep/Glob/Task/…) are deliberately excluded — this is about what the
AI *does*, not what it looks at. Subagent / workflow activity is included and tagged, and
can be hidden with one toggle.

## How it works

- Watches every `*.jsonl` transcript under `~/.claude/projects` (main sessions and nested
  subagent runs), polling once a second and reading only newly-appended lines.
- Each Claude `tool_use` of a system-touching tool becomes a row. The transcript envelope
  supplies the `sessionId` (the thread), `cwd` (the project), timestamp, git branch, and
  whether it came from a subagent.

## Actions per row

- **Click / 🌐** — render the full thread to HTML and open it in your browser, scrolled
  to that command (subagent rows open the subagent's own transcript).
- **⌨️ terminal** — open Terminal in the project and run `claude --resume <sessionId>`.
- **📋 copy** — copy the command. Right-click for more (copy session id, reveal transcript).

Plus search, per-kind filters, a hide-subagents toggle, and pause.

## Install

Download the latest `ClaudeWatch.zip` from the
[Releases](https://github.com/adamXbot/ClaudeWatch/releases) page, unzip, and drag
`ClaudeWatch.app` to `/Applications`. The ✨ icon appears in your menu bar (no Dock icon).

Signed + notarized releases open normally. For an unsigned build, right-click → Open the
first time, or allow it under System Settings → Privacy & Security.

To launch at login: System Settings → General → Login Items → **+**.

Signed releases keep themselves up to date via [Sparkle](https://sparkle-project.org) —
check manually any time from Settings → General → **Check for Updates…**.

## Build from source

Requires macOS 13+ and a Swift toolchain (Xcode or Command Line Tools).

```sh
./build.sh            # produces ClaudeWatch.app
open ClaudeWatch.app
```

## Project layout

```
Sources/ClaudeWatchCore/   # pure, headless logic — unit-tested
  EventKind, CommandEvent, TranscriptParser, EventScanner,
  TranscriptStore, TranscriptHTMLRenderer, RelativeTime
Sources/ClaudeWatch/       # the SwiftUI menu-bar app
  ClaudeWatchApp, MenuContentView, CommandRowView, Actions, main
Tests/ClaudeWatchTests/    # XCTest coverage for the Core
```

```sh
swift test            # run the Core test suite
```

### Headless inspection

The same binary can dump the latest parsed actions as text — handy for verifying parsing
without the UI:

```sh
swift run ClaudeWatch --dump
```

## Releasing

Push a `vX.Y.Z` tag and CI builds, signs, notarizes, and publishes a GitHub Release
(and, once configured, a Sparkle auto-update appcast). The maintainer's signing/release
setup notes live in a local, untracked `RELEASING.md`.

## Notes

- "Resume in Claude Code" requires the `claude` CLI on your `PATH`.
- No telemetry, no network, no data leaves your machine.
