# Getting started

ClaudeWatch is a menu bar app that shows the system-touching actions
[Claude Code](https://claude.com/claude-code) and Codex run on your Mac: shell
commands, file writes and edits, notebook edits, web fetches and web searches.
Each row links back to the conversation that issued it.

It reads the transcripts those tools already keep on your disk, under
`~/.claude/projects` for Claude Code and `~/.codex/sessions` and
`~/.codex/archived_sessions` for Codex. It never writes to them.

## The menu bar items

There is no Dock icon. ClaudeWatch shows one menu bar item per source:

- A **sparkles** glyph for Claude Code.
- A **code brackets** glyph for Codex.
- A **magnifying glass** while neither source has any transcripts yet, so Settings stays reachable.

An item appears automatically once its source has transcripts. You can keep an item
on or off regardless in [Settings](06-settings.md). When a session is waiting on you,
its item becomes a **bell**.

Click an item to open its popover: the [activity feed](02-the-activity-feed.md) for
that source, the [active sessions](03-active-sessions.md) above it, and at the bottom
a gear for Settings (⌘,) and Quit ClaudeWatch (⌘Q).

## Opening ClaudeWatch at login

Turn on **Open ClaudeWatch at login** under Settings ▸ General. The caption under the
toggle reports what macOS says: enabled, waiting for your approval in System
Settings, or unavailable for this copy of the app.

## The main menu

ClaudeWatch has a main menu whenever one of its windows is open (Settings, About,
this manual or Keyboard Shortcuts). While they are closed it lives in the menu bar
only. The Help menu holds this manual and the Keyboard Shortcuts window (⌘?).

## Where to go next

- [The activity feed](02-the-activity-feed.md): reading rows, opening threads and resuming sessions.
- [Notification rules](04-notification-rules.md): being told when something happens.
- [Troubleshooting](07-troubleshooting.md) when an item or action does not behave.
