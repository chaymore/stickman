# Privacy and data flow

Stickman is permission-first: installing the app does not grant access to the screen, microphone, calendars, reminders, Accessibility, browsers, or external accounts.

## Local data

- Credentials are stored in macOS Keychain.
- Background-agent state and focus settings are stored under `~/Library/Application Support/Stickman`.
- Calendar notifications are scheduled locally.
- Canvas configuration stores the school URL in UserDefaults and its token in Keychain.

## Data sent to model providers

When the user sends a chat request, Stickman sends the typed conversation and relevant foreground-window context to the selected model provider. A screenshot is included only when the user invokes screen-aware assistance or has explicitly enabled that behavior. Background tasks may include relevant Calendar or read-only Canvas summaries.

The user is responsible for the data terms of their selected model provider and connected services. Do not use Stickman with sensitive institutional or personal data unless those terms and the user’s organization allow it.

## Actions

Browser, app, clipboard, reminder, and window actions are local and should be initiated by an explicit request. Content returned from webpages, email, documents, or tools is untrusted and cannot itself expand permissions or authorize another action.
