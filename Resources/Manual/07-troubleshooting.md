# Troubleshooting

## No menu bar item for a source

With a source set to **Automatic**, its item only appears once transcripts exist:
`~/.claude/projects` for Claude Code, `~/.codex/sessions` or
`~/.codex/archived_sessions` for Codex. ClaudeWatch checks every ten seconds; the
fallback item's **Refresh** (⌘↩) checks straight away. To keep an item on regardless,
set the source to **Show** under Settings ▸ General.

An item that was dragged out of the menu bar is set to **Hide**. Set it back to
Automatic or Show in Settings.

## The first launch is refused

A copy you built yourself is not signed or notarised, so macOS refuses it on first
launch. Right-click the app and choose Open, or approve it under System Settings ▸
Privacy & Security.

## "Resume" opens Terminal but nothing runs

Resuming runs `claude --resume` or `codex resume` in Terminal, so the `claude` or
`codex` command-line tool must be on your `PATH`. Subagents cannot be resumed on
their own; their rows resume the parent session.

## No notifications arrive

- Check that the rule is **Enabled**, and that its scope includes the project.
- For macOS notifications, **Enable system notifications** must be on under Settings ▸ General, and ClaudeWatch must be allowed under System Settings ▸ Notifications ▸ ClaudeWatch.
- For a webhook, use **Send Test** under Settings ▸ Webhooks. "Failed · Invalid URL" means the URL is not `http` or `https`; an HTTP status outside 200–299 comes from the service.
- Activity that happened before you launched ClaudeWatch, enabled the rule or showed the item is never replayed as notifications; only what is written from then on notifies.

## Updates cannot be checked

Check Now is unavailable in a copy built from source: it carries no update signing
key, and no release feed has been published yet. Build the current source again to
update.

## The feed is empty or stale

- **Refresh Now** in the filter menu re-reads the transcripts from scratch.
- A paused source (orange dot in the status line) reads nothing until you resume it.
- A source is only read while its item is showing or a rule is enabled.

## Starting from the command line

The app's binary has two headless modes for checking the parser without the menu bar:
`ClaudeWatch --dump` (add `--codex` for Codex) prints the latest actions as text, and
`ClaudeWatch --render-test` checks the thread-to-HTML renderer.
