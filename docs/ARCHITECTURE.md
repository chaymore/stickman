# Architecture

Stickman is a native AppKit accessory application built as a Swift Package executable and wrapped in a conventional `.app` bundle by `scripts/build-app.sh`.

## Main layers

- **Character:** `BuddyView.swift`, `StickmanWorld.swift`, `CompanionMode.swift`, `CombatDirector.swift`, and `ScreenEffectsOverlay.swift` implement the IK skeleton, gravity and ledge physics, peaceful behavior, sparring, and click-through effects.
- **Shell:** `AppDelegate.swift`, `BuddyWindowController.swift`, `StickmanCompanionPanel.swift`, and `StickmanStyle.swift` manage the menu bar, the character window and frame loop, the glass chat and settings panel, shortcuts, and window affinity.
- **Assistant:** `StickmanChatPanelView.swift`, `OpenAIResponsesClient.swift`, `RealtimeVoiceClient.swift`, and `BackgroundAgentCoordinator.swift` implement text, vision, voice, and persistent background jobs.
- **Local actions:** `ActionRunner.swift`, `BrowserControlService.swift`, `WindowActionService.swift`, and `WebsiteBlockerService.swift` handle explicit desktop actions.
- **Stickman Blocker:** `Blocker/` holds the shared core, root daemon, installer, and recovery tool. In the app, `StickmanBlocker.swift` owns status, the menu section, and helper installation, `BlockerBrowserService.swift` redirects blocked tabs, and `StickmanBlockPage.swift` renders the block page.
- **Computer use:** `ComputerUse/Sources/StickmanComputerUseMCP` is a stdio MCP server that Claude Code launches. It forwards each tool call to `ComputerUseService.swift`, which listens on a Unix socket that only the bundled relay may connect to, checks per-app approvals, and calls `ComputerUseEngine.swift` (accessibility outlines, ScreenCaptureKit window screenshots, and tagged CGEvent input). `ComputerUseOverlay.swift` draws the "esc to stop" banner and the approval prompt.
- **Permissions and context:** `PermissionCenterService.swift`, `DesktopContextProvider.swift`, `ScreenshotCaptureService.swift`, `ScreenShareMonitor.swift`, and `CalendarService.swift` isolate sensitive access and detect screen sharing.
- **Connections:** `ConnectorRegistryService.swift`, `CanvasService.swift`, and `ProactiveStudyService.swift` provide narrow account boundaries and calendar-triggered preparation.

## Persistence

- API and connector secrets: macOS Keychain
- Agent jobs and focus settings: `~/Library/Application Support/Stickman`
- Computer use: the socket and the generated `computer-use-mcp.json` in the same folder; always-allowed apps in UserDefaults
- Preferences: the app’s standard UserDefaults domain
- Screenshots: temporary files deleted after request completion

`LegacyMigrationService.swift` copies compatible Milo-era state forward without deleting the source data.

## Build outputs

The release builder compiles `arm64` and `x86_64` binaries, combines them with `lipo`, creates `dist/Stickman.app`, and applies either ad-hoc or Developer ID signing. `scripts/package-release.sh` creates a versioned zip and checksum and can submit for notarization through a Keychain profile.
