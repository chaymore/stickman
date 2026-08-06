# Contributing to Stickman

Thanks for helping make Stickman more useful and more alive.

## Setup

1. Install Xcode Command Line Tools with `xcode-select --install`.
2. Fork or clone the repository.
3. Run `swift test`.
4. Run `STICKMAN_ARCHS="$(uname -m)" ./scripts/build-app.sh` for a quick native build.
5. Add an API key with `./stickman --set-api-key` only when testing AI features.

No credential should ever be committed. Stickman reads API keys from environment variables or macOS Keychain.

## Pull requests

- Branch from `main` and keep each pull request focused.
- Add or update tests for behavior changes.
- Run `make verify` before requesting review.
- Include a screenshot or generated preview for visible UI or animation changes.
- Preserve the permission-first model: new sensitive capabilities must be independently explained, requested, and reversible.
- Keep task animations brief and interruptible so they do not interfere with work.

## Repository map

- `Sources/`: Stickman application and assistant services
- `Tests/StickmanTests/`: Swift Testing suites
- `Resources/`: runtime assets and signing entitlements
- `scripts/`: build, verification, and packaging tools
- `DesignConcepts/`: design research and generated preview artifacts
- `NightLock/`: optional, separately built focus-tool prototype
- `.github/workflows/`: clean-clone CI and tagged release automation

## Changing app identity

The default bundle ID is `com.chaymore.Stickman`. Forks can override it without editing source:

```bash
STICKMAN_BUNDLE_ID=com.example.Stickman ./scripts/build-app.sh
```

Do not rename existing UserDefaults or Keychain keys without a migration path.
