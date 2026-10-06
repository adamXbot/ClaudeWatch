# Active sessions

When a session is live, a strip above the feed lists it with a dot and a status:

- A **blue** dot means the session is working: a tool is running, or the assistant is producing output. The status reads "running: …" with the tool's description, or "working…".
- A **yellow** dot means the session is waiting on you: the turn ended, or it has gone idle. The status reads "awaiting you", or "idle" with how long.

Working is keyed off the main thread's own activity, so subagent output on its own
does not make a session look busy.

## The bell

While any session of a source is waiting, that source's menu bar glyph becomes a
**bell**, so you can see from across the screen that something needs you. It returns
to the usual glyph once the session is working again or has gone stale.

## Acting on a session

- Click a session to open its full thread in your browser.
- The **resume** button beside a waiting session opens Terminal in the project directory and resumes it in Claude Code or Codex, as the row buttons do in [the activity feed](02-the-activity-feed.md).

A session's project can be hidden with the feed's project filter; hidden projects
leave the strip too.

## Being told when a session finishes

A [notification rule](04-notification-rules.md) with the **Session done** trigger
fires when a session goes from working to waiting with every tool drained. That is a
genuine finish, not a stall.
