# Stickman

Native AppKit desktop companion for macOS (Swift Package, macOS 13+). A stick figure walks on your windows, chats, runs Claude Code sessions, can operate apps through computer use, and includes Stickman Blocker (a root-daemon site blocker). See `docs/ARCHITECTURE.md` and `REBUILD_NOTES.md` for where things live.

## Dev loop

- `scripts/dev-install.sh` copies the repo outside Google Drive, runs the tests, builds the universal app, installs it to `/Applications`, and restarts it through the blocker's launch agent. `SKIP_TESTS=1` skips tests. Don't run `swift build` inside this folder; Google Drive makes SwiftPM very slow.
- Tests use Swift Testing (`@Test`, `#expect`) in `Tests/StickmanTests` and `Blocker/Tests`.
- Builds sign with the self-signed "Stickman Local Signing" identity when it's in the login keychain, so Accessibility and Screen Recording grants survive reinstalls. If a build comes out ad-hoc (`codesign -d -r- /Applications/Stickman.app` shows `cdhash`), the identity is missing and grants will reset.
- Check visuals without taking over the screen: `Stickman --render-avatar-preview <png>`, `--render-avatar-animation-preview <gif>`, `--render-window-preview <png>`, `--render-block-page <png>`, and `--effects-demo` (opens a small window for 8 seconds; capture it with `screencapture -l <id>` using the printed `DEMO_WINDOW_ID`). Avoid live on-screen tests while the user is screen sharing.

## Computer use

`ComputerUse/Sources/StickmanComputerUseMCP` is the stdio MCP relay Claude Code launches (`stickman-computer-use` in the bundle). It forwards tool calls over `~/Library/Application Support/Stickman/computer-use.sock` to `ComputerUseService.swift`, which only accepts the bundled relay as a peer. `ComputerUseEngine.swift` does the accessibility outline, window screenshots, and input; `ComputerUseOverlay.swift` draws the esc banner and the per-app approval prompt.

Smoke test through the real path: `scripts/computer-use-call.py list_apps`, then `get_app_state '{"app":"TextEdit"}'` and so on. Screenshots land in `$TMPDIR/stickman-cu-shots`.

## Claude Code integration

Stickman runs Claude Code under the personal profile (`CLAUDE_CONFIG_DIR=~/.claude-personal`). `/claude`, `/cloud`, and `/computer` in chat map to `ClaudeCodeService`; computer-use sessions add `--model opus --mcp-config <support>/computer-use-mcp.json --allowedTools mcp__stickman`.

## Rules

- Commit or push only when the user asks.
- Keep Stickman Blocker's protections intact: no bypasses, and the recovery key flow stays as is.
- Computer use stays approval-gated per app, with terminals, password managers, and System Settings off-limits and password fields never typed into.
- User-facing text: plain and direct, no em dashes.
