# Notification rules

Rules tell ClaudeWatch when to notify you. Each one has a trigger, a scope and one or
more destinations. Manage them under Settings ▸ Rules.

## Adding a rule

**Add Rule** offers a blank rule, each of the starter rules, or all of the starter
rules at once:

- **Git commit**: a shell command containing `git commit`.
- **Any file write**: every `Write`.
- **Session done**: a session finishing.

A rule has a name, and an **Enabled** toggle to switch it off without deleting it.

## When a rule fires

**Action** rules fire on a matching system-touching action:

- **Action type** narrows it to one kind (Shell, Write, Edit, Notebook, Fetch, Search) or Any.
- **Text contains** is matched, ignoring case, against the command or path and its description. Leave it empty to match every action of the chosen type.
- **Match as a regular expression** treats that text as a regular expression instead of a plain substring. A pattern that does not compile matches nothing.

**Session done** rules fire when a session goes from working to waiting with all of
its tools drained; see [Active sessions](03-active-sessions.md).

Rules are not tied to a source. An enabled rule keeps both the Claude and Codex
transcripts watched, even while a source's menu bar item is hidden.

Starting ClaudeWatch, enabling a rule or showing an item catches up on history
quietly: old activity is never replayed as fresh notifications.

## Which projects

**All projects** applies the rule everywhere. Turn it off to pick projects from the
list, which comes from the projects seen in the feeds so far.

## Where the notification goes

- **Send a system notification** posts a macOS notification. It needs **Enable system notifications** on under Settings ▸ General, and macOS's permission, which it asks for the first time.
- **Send to <webhook>** posts to a webhook you have added under Settings ▸ Webhooks. See [Webhooks](05-webhooks.md).

Each distinct action notifies a rule once, so a transcript that is re-read does not
notify again.

## Deleting a rule

**Delete Rule…** asks for confirmation first. A deleted rule cannot be recovered;
disable it instead if you may want it back.
