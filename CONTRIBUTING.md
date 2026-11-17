# Contributing to Rearview

Thank you for helping. Rearview is a SwiftPM project with no Xcode project file.

## Set up
- macOS 14+ with Xcode 16 (Swift 6). `make build`, `make test`, `make lint`, `make app`, `make dmg`.
- On Linux you can work on `RearviewCore` with the Swift 6 toolchain: `swift test --filter RearviewCoreTests`.
- To use Xcode, open `Package.swift` directly.

## Rules
- Swift 6 language mode, strict concurrency, no warnings (CI builds with `-warnings-as-errors`).
- Format with `make format`; CI runs `swift format lint --strict`.
- Logic that does not need Apple frameworks goes in `RearviewCore`, with tests.
- No network code. CI fails if it finds `URLSession` and friends in `Sources/`.
- UI changes: run `make snapshots` and attach the PNGs to your pull request.

## Signing and notarization (maintainers)
CI signs ad hoc by default. If the repository has these secrets, CI signs with a Developer ID and notarizes:

| Secret | Meaning |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application certificate + key, `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID |

Without them the signing and notarization steps are skipped cleanly.

## Releases
Push a tag `vX.Y.Z` on `main`. CI builds, verifies and attaches the DMG to a GitHub Release.
