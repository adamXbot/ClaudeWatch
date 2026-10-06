# Webhooks

A webhook lets a [notification rule](04-notification-rules.md) post to a chat
service or your own endpoint. Manage them under Settings ▸ Webhooks.

## Providers

- **Discord**: an incoming webhook URL from a channel's integrations. ClaudeWatch sends `{"content": …}`.
- **Slack**: an incoming webhook URL. ClaudeWatch sends `{"text": …}`.
- **Microsoft Teams**: an incoming webhook URL. ClaudeWatch sends a legacy MessageCard with the text.
- **Generic JSON**: any endpoint that accepts a POST with a JSON body of `{"text": …}`.

## Adding a webhook

Under **Add webhook**, give it a name (the provider's name is used if you leave it
empty), choose the provider, paste the URL and click **Add Webhook**. The new webhook
then appears as a destination toggle on every rule.

## Where the URL is kept

Webhook URLs usually carry a token, so ClaudeWatch stores them in your macOS
Keychain, not in its preferences. Only the name and provider live in preferences.

## Testing and changing a webhook

Each webhook's section shows its provider and URL. Change the URL and click **Save**
to store the new one. **Send Test** posts a test message and reports the result
beside the buttons: "Delivered" with the HTTP status, or "Failed" with the reason.

## Removing a webhook

**Remove Webhook…** asks for confirmation. Removing one deletes its URL from the
Keychain and takes it off every rule that sent to it.
