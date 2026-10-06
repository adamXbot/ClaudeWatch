# Settings

Open Settings with ⌘, from the main menu, or with the gear at the bottom of any
menu bar popover. The window has four tabs.

## General

- **Open ClaudeWatch at login**: registers the app as a login item. The caption reports the real state: enabled, waiting for approval in System Settings ▸ General ▸ Login Items, or unavailable for this copy of the app.
- **Claude** and **Codex** each choose when that source's menu bar item shows: **Automatic** shows it only while the source has transcripts, **Show** keeps it on, **Hide** turns it off. Dragging an item out of the menu bar sets it to Hide. While neither source shows an item, a fallback item keeps Settings reachable.
- **Enable system notifications**: lets rules post macOS notifications. macOS asks for permission the first time; change it later in System Settings ▸ Notifications ▸ ClaudeWatch.
- **About ClaudeWatch** opens the About window: version and build, what the app does, links to the source and the issue tracker, this manual, the keyboard shortcuts, and the licences of bundled software.

## Rules

Your [notification rules](04-notification-rules.md): the Add Rule menu, then one
section per rule.

## Webhooks

Your [webhooks](05-webhooks.md): one section per webhook, then the form to add one.

## Updates

ClaudeWatch updates itself through Sparkle once a signed release has been published.

- **This version** shows the version and channel, and when updates were last checked.
- **Check for updates automatically** is off until you turn it on; then choose how often: daily, weekly or monthly.
- **Check Now** checks immediately. The same check is in the app menu as **Check for Updates…**.
- **Release Notes** opens the releases page in your browser.

A copy you built yourself has no update signing key, so it cannot check for updates;
see [Troubleshooting](07-troubleshooting.md).
