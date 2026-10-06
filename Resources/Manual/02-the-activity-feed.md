# The activity feed

The popover behind a source's menu bar item lists that source's system-touching
actions, newest first. The strip of [active sessions](03-active-sessions.md) sits
above it when any session is live.

## What becomes a row

From Claude Code: `Bash` (the command and its description), `Write` (path and size),
`Edit` and `MultiEdit` (path), `NotebookEdit` (notebook and edit mode), `WebFetch`
(URL) and `WebSearch` (query).

From Codex: `exec_command`, `write_stdin`, `apply_patch` and `js` (its Node REPL),
whether each is recorded on its own or as a call inside an `exec` script. A script is
read, not run, so a command it builds as it goes shows as "(computed command)".

Read-only tools (Read, Grep, Glob, Task and friends) are left out on purpose. The feed
is about what the AI *does* to your machine, not what it looks at.

Each row shows the kind of action as a coloured glyph, the command or path, the
project it ran in, a short description where there is one, how long ago it happened,
and a **subagent** badge when a nested agent issued it.

## Opening the thread

Click a row to render the whole conversation to HTML and open it in your browser,
scrolled to that command. A subagent row opens the subagent's own transcript, which is
exactly the thread that issued the command.

Hover a row for three buttons:

- **Globe**: view the thread in your browser, as above.
- **Terminal**: resume the session. ClaudeWatch opens Terminal in the project directory and runs `claude --resume <session>` or `codex resume <session>`. A subagent's row resumes its parent session, since subagents cannot be resumed on their own.
- **Copy**: copy the command to the clipboard.

Right-click a row for the same actions plus **Copy session id** and **Reveal transcript
in Finder**.

## Searching and filtering

The field under the header filters rows by command, project or description as you type.

The filter menu at the top right offers:

- **Show subagent activity**: hide or show rows from nested agents.
- One toggle per kind of action: Shell, Write, Edit, Notebook, Fetch, Search.
- **Projects**: a submenu with a toggle per project, and Show All.
- **Pause watching**: stop reading new activity until you resume. The header shows a "paused" pill, and the status line's dot turns orange.
- **Refresh Now**: re-read the transcripts from scratch. A refresh rebuilds the feed quietly; it never replays old activity as notifications.

## The status line

Above the footer, the status line counts the rows that match your filter and names
the folder being watched (`~/.claude` or `~/.codex`). The button beside it pauses and
resumes watching, the same as the filter menu's toggle.

## How reading works

ClaudeWatch is told by macOS which transcript files changed and reads only their
newly appended lines, so a quiet history costs nothing. On launch it reads the
sessions of the last day and as much older history as the feed shows. A source is
only read while something needs it: its menu bar item is showing, or a
[notification rule](04-notification-rules.md) is enabled.
