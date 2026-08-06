# NightLock

NightLock is a native macOS bedtime website blocker packaged as one app. It protects every day from 10:00 PM to 5:00 AM and blocks Facebook, Instagram, LinkedIn, Netflix, YouTube, Reddit, and X.

## Architecture

- A root LaunchDaemon enforces the block through a managed section in `/etc/hosts`.
- A per-user LaunchAgent keeps the NightLock menu bar app running and relaunches it if it exits.
- The menu bar app redirects blocked Safari and Chrome tabs to a local NightLock page.
- Quitting or force-quitting the UI does not stop daemon enforcement.
- Schedule and enabled-state changes require the generated recovery key.

An administrator who owns the Mac can always dismantle locally installed software with enough effort. NightLock is designed to remove casual and impulsive bypasses, not defeat a determined system administrator.

## Build And Install

```zsh
cd NightLock
./nightlock --install
```

Installation copies the single app bundle to `/Applications`, generates the split recovery key, installs the root daemon and login agent, and starts both services. macOS will ask for administrator approval and browser Automation permission.

## Normal Use

NightLock appears as a shield icon in the menu bar. The menu shows current status and schedule. Protected Settings lets you change the schedule or enabled state only after entering the recovered emergency key.

There is intentionally no Quit command and no snooze.

## Recovery

Read `RECOVERY.md` before attempting emergency recovery. The operation requires administrator access and includes a deliberate delay.
