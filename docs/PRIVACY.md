# Privacy and data flow

Stickman is permission-first: installing the app does not grant access to the screen, microphone, calendars, reminders, Accessibility, browsers, or external accounts.

## Local data

- Credentials are stored in macOS Keychain.
- Background-agent state and focus settings are stored under `~/Library/Application Support/Stickman`.
- Calendar notifications are scheduled locally.
- Canvas configuration stores the school URL in UserDefaults and its token in Keychain.
- Screen-share detection reads a yes-or-no flag from the window server about whether any capture is running. It never captures, reads, or stores screen content, and needs no permission.

## Data sent to model providers

When the user sends a chat request, Stickman sends the typed conversation and relevant foreground-window context to the selected model provider. A screenshot is included only when the user invokes screen-aware assistance or has explicitly enabled that behavior. Background tasks may include relevant Calendar or read-only Canvas summaries.

The user is responsible for the data terms of their selected model provider and connected services. Do not use Stickman with sensitive institutional or personal data unless those terms and the user’s organization allow it.

## Computer use

When you ask Claude to use your computer (`/computer`, "use my computer to…", or the voice equivalent), Stickman starts a Claude Code session on Opus that can operate apps through Stickman. The `stickman-computer-use` tool inside the app bundle passes Claude's requests to Stickman over a private socket that only that tool can use. Stickman reads the app's accessibility outline, screenshots only that app's front window, and posts clicks and keystrokes.

- Claude must get your approval the first time it uses each app. "Always Allow" choices are stored in UserDefaults and can be removed in **Settings → Claude Code**.
- Terminals, password managers, Keychain Access, System Settings, and Stickman itself are off-limits. Password fields are never typed into or read.
- A banner shows while Claude is working. Pressing esc stops it, and further requests are refused for two minutes or until you start a new task.
- Screenshots and outlines go to Anthropic as part of that Claude Code session, under your personal account.

## Actions

Browser, app, clipboard, reminder, and window actions are local and should be initiated by an explicit request. Content returned from webpages, email, documents, or tools is untrusted and cannot itself expand permissions or authorize another action.
