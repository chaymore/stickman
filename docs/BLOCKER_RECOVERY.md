# Stickman Blocker Emergency Recovery

Use this only when you genuinely need to change or disable Stickman Blocker and accept breaking the barrier you set for yourself.

Stickman Blocker (then called NightLock) generated a random 64-character recovery key during first installation. It never stored the complete key in one place. The two root-only shares are held separately at:

- `/var/db/NightLock/.recovery-part-1`
- `/Library/Application Support/NightLock/.recovery/.recovery-part-2`

The bundled recovery utility reads and combines both shares. It requires administrator access and waits 30 seconds before revealing the key:

```zsh
./stickman --recover-blocker
```

Enter the revealed key in Stickman's menu bar menu → Protected Settings. The daemon validates it before applying any schedule or enabled-state change.

Reinstalling or rebuilding Stickman Blocker preserves the existing key and protected configuration. Deleting the configuration or daemon manually is an administrator-level dismantling operation and is intentionally not exposed as an app command.
