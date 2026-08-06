# Distribution

## Local or collaborator builds

Run `make package` to create:

- `dist/Stickman.app`
- `dist/Stickman-<version>-macos-universal.zip`
- a matching SHA-256 checksum

The default archive is universal and ad-hoc signed. It is appropriate for local development and CI artifacts, but Gatekeeper may warn when another person downloads it.

## Public notarized releases

A warning-free public build requires Apple Developer Program membership, a `Developer ID Application` certificate, and notarization credentials.

For a local notarized package:

```bash
xcrun notarytool store-credentials StickmanNotary
export STICKMAN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export STICKMAN_NOTARY_PROFILE=StickmanNotary
make package
```

For GitHub Actions, configure these repository secrets:

- `STICKMAN_CERTIFICATE_P12`: base64-encoded Developer ID certificate and private key
- `STICKMAN_CERTIFICATE_PASSWORD`
- `STICKMAN_CI_KEYCHAIN_PASSWORD`
- `STICKMAN_SIGN_IDENTITY`
- `STICKMAN_NOTARY_APPLE_ID`
- `STICKMAN_NOTARY_PASSWORD`: an app-specific Apple ID password
- `STICKMAN_NOTARY_TEAM_ID`

Pushing a tag such as `v0.5.0` runs tests, builds the universal app, optionally signs and notarizes it when secrets are present, and creates a GitHub release with the archive and checksum.

Never commit certificates, private keys, Apple credentials, or API tokens.
