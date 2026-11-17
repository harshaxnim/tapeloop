# Contributing to Tapeloop

Thank you for helping. Tapeloop is a Swift package with no Xcode project file. Read
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and the [developer guide](docs/features/tapeloop/dev.md) first.

## Set up

- macOS 14 or later with Xcode 16.2 (Swift 6.0) or later. CI uses Xcode 16.2.
- To use Xcode, open `Package.swift` directly.
- On Linux you can work on `TapeloopCore` with the Swift 6 toolchain: `swift test --filter TapeloopCoreTests`.

| Command | What it does |
|---|---|
| `make build` | Debug build |
| `make test` | All unit tests (about one minute) |
| `make format` | Formats `Package.swift`, `Sources` and `Tests` in place with `swift format` |
| `make lint` | `swift format lint --strict` |
| `make app` / `make run` | Builds `build/Tapeloop.app` for this Mac (ad-hoc signed) / and opens it |
| `make snapshots` | Renders every screen, light and dark, to `build/snapshots` |
| `make dmg` / `make verify` | Universal app and DMG / checks the DMG |
| `make probe` | Records 10 s of microphone and system audio through the app bundle and prints a report |

Ad-hoc signatures change with every build, so macOS asks for the permissions again after each rebuild. To avoid
that, create a code-signing identity in your keychain (a self-signed one is enough) and build with
`SIGN_IDENTITY="<its name>" make app`.

## Rules

- **Swift 6 language mode with strict concurrency.** CI builds with `swift build -Xswiftc -warnings-as-errors`, so
  a warning fails the build.
- **Format and lint.** Run `make format` before you commit. CI re-formats and fails on any difference, then runs
  `swift format lint --strict` (120 columns, see `.swift-format`).
- **No network code, with one exception.** Tapeloop promises that nothing leaves the Mac. The only network code
  allowed is the speech-model download the user starts, in `Sources/TapeloopParakeet/ModelDownloader.swift`; it
  fetches one file from Tapeloop's own GitHub release and checks its SHA-256. CI fails if `URLSession`,
  `NWConnection`, `URLRequest`, `CFSocket` or `NSStream` appears in any other file in `Sources`. Do not add
  analytics, crash reporting, update checks or cloud features, and do not add other downloads.
- **Tests.** Logic that does not need Apple frameworks goes in `TapeloopCore`, with tests. Audio, export and
  intelligence code is tested with synthetic audio and fakes; tests must not need a microphone, a permission or
  the network. Tests that need the Parakeet model skip themselves when it is not installed (as on CI).
- **UI.** Views go in `TapeloopUI` and use the `Tape` theme (flat, 3-point corners, the amber accent). Views get
  system facts through `SettingsServices` and sample data, so they render in `make snapshots`. Attach the changed
  PNGs to your pull request.
- **Documentation.** Update [CHANGELOG.md](CHANGELOG.md) under "Unreleased", and the user, admin or developer
  guides in `docs/features/tapeloop/` when behaviour changes. The manual release test plan is in
  [docs/TESTING.md](docs/TESTING.md).
- **Security issues** go through [SECURITY.md](SECURITY.md), not public issues.

## Signing and notarization (maintainers)

CI signs ad hoc by default. If the repository has these secrets, CI signs with a Developer ID and the hardened
runtime, and notarizes and staples the DMG:

| Secret | Meaning |
|---|---|
| `MACOS_CERT_P12` | Developer ID Application certificate and key, `.p12`, base64-encoded |
| `MACOS_CERT_PASSWORD` | Password of that `.p12` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | Team ID |
| `APPLE_APP_PASSWORD` | App-specific password for that Apple ID |

Without them the signing and notarization steps are skipped cleanly.

## Releases

Run the manual plan in [docs/TESTING.md](docs/TESTING.md), move the "Unreleased" changelog entries under the new
version, then push a tag `vX.Y.Z` on `main`. CI builds, tests, verifies the DMG and attaches it with its `.sha256`
to a GitHub Release. A tag with a hyphen (for example `v0.2.0-rc1`) is published as a pre-release. Details are in
the [developer guide](docs/features/tapeloop/dev.md#release).
