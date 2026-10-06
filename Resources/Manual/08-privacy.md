# Privacy and data

## What ClaudeWatch reads

The transcripts Claude Code and Codex already keep on your Mac:

- `~/.claude/projects`: every `*.jsonl` transcript, including nested subagent runs.
- `~/.codex/sessions` and `~/.codex/archived_sessions`.

It opens them read-only and never writes to them. A source is read only while its
menu bar item is showing or a notification rule is enabled.

## What ClaudeWatch writes

- Preferences: rules, webhook names and providers, the menu bar settings, and the notification toggle.
- Webhook URLs, in your macOS Keychain.
- When you open a thread in the browser, a rendered HTML copy of that transcript in a temporary folder.

## What leaves your Mac

There is no telemetry. Two things do go out, both under your control:

- **Webhooks** post a notification's text to the URL you configured, when a rule with that destination fires or when you click Send Test.
- **Updates** through Sparkle poll the release feed when you click Check Now, or on the schedule you choose. Automatic checks are off until you turn them on.

## Licence

ClaudeWatch is open source under the MIT License. The About window links to the
source and lists the licences of the software it bundles.
