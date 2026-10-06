# Stickman Rebuild Notes

## Product shape

Stickman has two deliberately separate modes:

- Peaceful: ambient companion, text and realtime voice, on-demand screen context, visual walkthrough markers, focus sessions, app actions, Reminders, clipboard, and window placement.
- Sparring: procedural skeletal animation, global cursor velocity detection, direct-hit reactions, autonomous attacks, limited cursor recoil/tugging, and screen-wide click-through effects.

Sparring never synthesizes clicks, edits documents, closes apps, or changes another app's data. “Damage” to the desktop is simulated in a transparent `ignoresMouseEvents` overlay. Cursor warps are small, time-bounded, and active only while the user has explicitly entered sparring mode.

## Architecture

- `BuddyView.swift`: procedural stick-figure poses solved with two-bone IK so limbs keep their length, eased crossfades between states, and a distance-driven gait that keeps planted feet from sliding.
- `StickmanWorld.swift`: walkable ledges built from the on-screen window list, a ballistic jump solver, and the body simulation for walking, leaping, falling, riding moving windows, and being thrown.
- `BuddyWindowController.swift`: the 60 fps frame loop, drag and throw, idle wandering and resting, window perching, and sparring knockback.
- `StickmanCompanionPanel.swift` and `StickmanStyle.swift`: the floating glass panel beside Stickman and the shared native styling.
- `ClaudeCodeService.swift`, `ClaudeCodeCommand.swift`, `ClaudeSessionsView.swift`, and `ClaudeCodeSettingsView.swift`: Claude Code background and cloud sessions on a separate `CLAUDE_CONFIG_DIR` profile, chat and voice commands, the sessions list, and settings.
- `ScreenShareMonitor.swift`: debounced screen-capture detection through the private `CGSIsScreenWatcherPresent`, so Stickman hides during screen shares.
- `CombatDirector.swift`: cursor velocity, hit detection, attack selection, cursor recoil, and truce-circle recognition.
- `ScreenEffectsOverlay.swift`: per-display transparent panels for impacts, slashes, tethers, transitions, and helper annotations.
- `CompanionMode.swift`: shared peaceful/sparring mode state and notifications.
- `StickmanChatPanelView.swift`: request-scoped screen capture and response marker parsing.
- `WindowActionService.swift`: explicit user-requested window placement through macOS Accessibility.
- `NightLockBridge.swift`: read-only status bridge to the installed protected NightLock service.
- `WebsiteBlockerService.swift`: flexible bedtime guard plus temporary focus sessions.
- `OpenRouterClient.swift`: optional Keychain-backed provider path; OpenAI remains the default when configured.
- `BackgroundAgentCoordinator.swift`: persistent OpenAI background jobs, polling, cancellation, completion notifications, and explicit browser-link handoff.
- `BrowserControlService.swift`: native Chrome tab listing, opening, searching, and activation through macOS Automation.
- `PermissionCenterService.swift`: independently requested macOS permission states and System Settings handoff.
- `CalendarService.swift` and `CalendarNudgeService.swift`: native schedule context plus local event notifications.
- `ConnectorRegistryService.swift` and `CanvasService.swift`: Keychain-backed account boundaries and read-only Canvas coursework context.
- `ProactiveStudyService.swift`: opt-out calendar-triggered preparation for clearly named study blocks.

## Interaction map

- `Option+B`: show or hide Stickman.
- `Option+Space`: peaceful quick assist with fresh screen context.
- `Option+F`: call a truce while sparring.
- `Control+-`: open Stickman's chat menu.
- `Control+Option`: open Stickman and start voice mode.
- Menu bar stickman: open chat or settings, start voice, inspect background agents, hide/show Stickman, or quit.
- Double-click: chat.
- Single click: a small hop. Wakes him if he is resting.
- Drag and release: pick him up and throw him.
- Option+triple-click: the only way to challenge Stickman. "Stop Fighting" in the menu bar ends it.
- Option+right-click a window: he climbs onto its top edge. Option+right-click empty space: he walks to the ledge below it. Plain right-clicks are left alone.
- Screen sharing or recording: Stickman and his panel fade out until the capture stops. "Show Stickman Anyway" in the menu bar overrides it for that share.
- Circle Stickman during a fight: truce.
- Remain on one foreground window for a minute: Stickman walks or leaps to its top-right corner and sits cross-legged until the window changes or closes.
- Idle: he strolls, hops between windows, and fidgets every half minute or so. He sits after about 2.5 quiet minutes and sleeps after 7. Wandering can be turned off in Settings.
- Agent launch: Stickman waves and opens a small portal beside his raised hand.
- Chrome action: Stickman flicks a magic wand and materializes a tab.
- Calendar, permission, and connector work each have their own short, interruptible gesture.

## Research applied

- HeyClicky's useful interaction pattern: screen context only when summoned, spoken help, screen drawing, and task actions.
- HeyClicky's agent pattern: voice-launched background work with a visible active/done queue while the user keeps working.
- Alan Becker's animation teaching: readable silhouettes, anticipation, primary action, overshoot, settle, arcs, follow-through, and pose-to-pose planning.
- Apple's ScreenCaptureKit and Accessibility guidance: visible permission boundaries and request-scoped control.

All character artwork and motion are generated by Stickman's local renderer. No frames, logos, video assets, or character files from Animator vs. Animation are bundled.
