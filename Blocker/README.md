# Stickman Blocker

Stickman Blocker is the protected website blocker built into Stickman. It used to ship on its own as NightLock, then Night Routine. It is always active and manages Instagram, Messenger, Netflix, Reddit, and X. Facebook, LinkedIn, and YouTube are unrestricted.

Instagram receives an independent continuous 30-minute window each day. X is unrestricted from 8:00 AM to 5:00 PM, has one continuous 10-minute window from 5:00 PM to midnight, and is blocked from midnight to 8:00 AM. Timers begin on the first attempted visit in an eligible window and reset at midnight. Messenger and all other configured sites remain blocked continuously.

## Architecture

- A root LaunchDaemon (`com.chaymore.NightLock.daemon`) enforces the block through a managed section in `/etc/hosts`.
- A per-user LaunchAgent (`com.chaymore.NightLock.agent`) keeps Stickman running and relaunches it if it exits.
- Stickman redirects blocked Safari and Chrome tabs to the local "Blocked by Stickman" page and reports allowance use to the daemon.
- Quitting or force-quitting Stickman does not stop enforcement. Once the blocker is installed, Stickman has no Quit command; `Option+B` tucks him into the notch instead.
- Schedule and enabled-state changes require the generated recovery key.

Internal labels and paths keep the `NightLock` name on purpose. Existing installs keep their recovery key, protected configuration, and `/etc/hosts` section when they upgrade.

An administrator who owns the Mac can always dismantle locally installed software with enough effort. Stickman Blocker is designed to remove casual and impulsive bypasses, not defeat a determined system administrator.

## Code

- `Sources/NightLockCore`: policy, file formats, and paths shared by everything below.
- `Sources/StickmanBlockerDaemon`: the root daemon.
- `Sources/StickmanBlockerInstaller`: installs or repairs the daemon and agent. Run as root.
- `Sources/StickmanBlockerRecover`: reveals the split recovery key after a delay. Run with sudo.
- The app side lives in Stickman's `Sources`: `StickmanBlocker.swift`, `BlockerBrowserService.swift`, `BlockerSettingsWindowController.swift`, `RoutineWindowController.swift`, and `StickmanBlockPage.swift`.

All of it builds from the root `Package.swift`, and `scripts/build-app.sh` bundles the daemon, installer, and recovery tool into `Stickman.app`.

## Install

From the repository root:

```zsh
./stickman --install-app
./stickman --install-blocker
```

Or choose **Install Blocker Helper…** from Stickman's menu bar menu. macOS asks for administrator approval. Upgrading from Night Routine.app works the same way: Stickman offers to move the blocker over, and the installer removes the old app.

## Normal use

Stickman's menu bar menu shows the blocker's status, schedule, and allowances. **Night Routine…** opens the routine window, and **Protected Settings…** changes the schedule or enabled state after you enter the recovery key. There is intentionally no snooze.

## Recovery

Read `docs/BLOCKER_RECOVERY.md` before attempting emergency recovery. It requires administrator access and includes a deliberate delay.
