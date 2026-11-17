# Tapeloop developer guide

This guide is for people who build, change or release Tapeloop. End users read the
[user guide](user-guide.html); people who manage Macs read the [admin guide](admin-guide.html).

## Architecture in one page

Tapeloop is a SwiftPM package of six libraries, the app and a snapshot tool, plus the vendored speech engine
transcribe.cpp in `ThirdParty/TranscribeCpp`. Full details, with diagrams, are in
[ARCHITECTURE.md](../../ARCHITECTURE.md).

- **Pipeline** ([§2](../../ARCHITECTURE.md#2-the-audio-pipeline)): `MicrophoneSource` (AVAudioEngine) and
  `SystemAudioTap` (Core Audio process tap, macOS 14.2+) deliver PCM with host-time stamps → `CaptureSink` (one per
  source, `NSLock`) → `AACEncoder` (48 kHz mono AAC-LC, ~5 s `EncodedChunk`s, exact gaps) → `SourceBuffer`
  (`ChunkRing` in RAM, optional `DiskSpillStore`) → on save, `Exporter` (`M4AWriter` passthrough or `Mixer`).
- **Budget** ([§2.4](../../ARCHITECTURE.md#24-memory-budgeting)): `MemoryBudget` plans RAM only, spill, or
  shortened. Memory pressure keeps 50 % (warning) or 25 % (critical) of the RAM part.
- **Threading** ([§3](../../ARCHITECTURE.md#3-threading)): capture threads under the sink lock; the engine is
  lock-protected and callable from any thread; the app and every view model are `@MainActor`; saves run in a
  detached task; meeting detection polls on its own queue.
- **App layer** ([§4](../../ARCHITECTURE.md#4-the-app-and-ui-layer)): `AppController` is the brain and builds a
  plain `PopoverState`; `SettingsModel` talks to the system only through `SettingsServices`; `LibraryModel` uses
  `LibraryStore`; `OnboardingModel` drives the welcome guide; `Windows` switches the app between accessory and
  regular activation while windows are open.
- **Data** ([§5](../../ARCHITECTURE.md#5-sidecar-metadata)): recordings are plain `.m4a`; metadata is a JSON sidecar
  in `<save folder>/.tapeloop/`. Settings are one JSON blob under the defaults key `appSettings`.
- **Intelligence** ([§6](../../ARCHITECTURE.md#6-meeting-detection), [§7](../../ARCHITECTURE.md#7-calendar),
  [§9](../../ARCHITECTURE.md#9-transcription)): `MeetingDetector`, `CalendarProvider`, `TranscriptionService` with
  the `Transcriber` seam, and `AppleSpeechTranscriber`.
- **Parakeet** ([§9](../../ARCHITECTURE.md#9-transcription)): `TapeloopParakeet` (macOS only) holds `ModelStore`
  (the model file and Tapeloop's only network code), `ParakeetEngine` (transcribe.cpp), `ParakeetTranscriber`
  (after a save) and `LiveTranscriber` (while recording).

## Build, run and debug

Requirements: macOS 14+, Xcode 16.2 (Swift 6.0) or later. CI pins Xcode 16.2 on `macos-15`.

```sh
make build        # swift build (debug)
make test         # swift test
make app          # build/Tapeloop.app for this Mac's architecture, signed by scripts/sign.sh
make run          # make app && open build/Tapeloop.app
make snapshots    # swift run TapeloopSnapshots build/snapshots
make probe        # 10 s capture test through the app bundle; PROBE_SECONDS=30 make probe for longer
make dmg verify   # universal app, DMG, DMG checks
```

- **Permissions while developing.** macOS attaches permissions to the code signature. `make app` signs ad hoc by
  default, so every rebuild is a new app to macOS and the prompts return. Sign with a stable identity instead:
  create a self-signed code-signing certificate in Keychain Access (for example "Tapeloop Local"), then run
  `SIGN_IDENTITY="Tapeloop Local" make app`. To start over, run
  `tccutil reset All io.github.harshaxnim.tapeloop`.
- **Run from the bundle.** Capture must run from `build/Tapeloop.app` (opened with `open`), not from
  `swift run Tapeloop`, so that macOS attributes the permissions to the app bundle and reads its usage strings.
- **Logs.** `os.Logger`, subsystem `io.github.harshaxnim.tapeloop`:

  ```sh
  /usr/bin/log stream --info --predicate 'subsystem == "io.github.harshaxnim.tapeloop"'
  /usr/bin/log show --info --last 30m --predicate 'subsystem == "io.github.harshaxnim.tapeloop" AND category == "engine"'
  ```

  Categories: `app`, `engine`, `mic`, `system-audio`, `encoder`, `meetings`, `calendar`, `transcription`,
  `intelligence`, `models`, `parakeet`, `live-transcription`, `hotkeys`, `services`, `library`, `library-player`,
  `probe`.
- **Reset the app's state.** Quit Tapeloop, then `defaults delete io.github.harshaxnim.tapeloop` (settings and the
  welcome-guide flag). The buffer itself never survives a quit. The speech model is kept in
  `~/Library/Application Support/Tapeloop/Models`; delete that folder to test the download again.
- **Snapshots of one screen.** `swift run TapeloopSnapshots /tmp/snaps popover` renders only names containing
  "popover".

## Tests

`swift test` runs 103 XCTest tests in four targets (counted on 17 November 2026 with the speech model installed,
all passing, about one minute). Run `swift test 2>&1 | grep Executed` for the current total. The per-test
descriptions are in [TESTING.md](../../TESTING.md#1-automated-tests).

| Target | Tests | Suites (tests) | Runs on |
|---|---:|---|---|
| `TapeloopCoreTests` | 53 | `ChunkRingTests` (5), `SourceBufferTests` (10), `RecorderSettingsTests` (4), `MemoryBudgetTests` (3), `LibraryStoreTests` (14), `TimeRangeTests` (5), `RecordingNameTests` (2), `TranscriptFormatterTests` (5), `TranscriptionSettingsTests` (5) | macOS, Linux |
| `TapeloopAudioTests` | 11 | `EncodeAndWriteTests` (1), `ExportTests` (8), `RecorderEngineTests` (2) | macOS |
| `TapeloopIntelligenceTests` | 29 | `MeetingDetectorTests` (12), `CalendarMatchTests` (6), `TranscriptionTests` (11) | macOS |
| `TapeloopParakeetTests` | 10 | `EngineTests` (2), `ModelStoreTests` (4), `TokenWordTests` (2), `LiveTranscriberTests` (2) | macOS |

Useful filters:

```sh
swift test --filter TapeloopCoreTests          # fast, also on Linux
swift test --filter MeetingDetectorTests
swift test --filter ExportTests                # the slow ones (~35 s): real encode/decode
swift test --filter TapeloopParakeetTests      # Parakeet; two tests need the installed model
```

`testTranscribesSpeech` and `testLiveLinesCoverASavedSpan` speak a sentence with the system `say` voice and
transcribe it with the real model. They skip themselves when the model is not in
`~/Library/Application Support/Tapeloop/Models`, as on CI; install it from Settings › Transcripts or copy the file
there to run them. The model-store tests use a small fake catalog entry whose URL is a local file, so they need no
network.

The tests use synthetic PCM, `RecorderEngine`'s `makeSource` injection for fake sources, an
`AudioProcessProvider` fake and a test clock for the meeting detector, and a fake `Transcriber`. The UI and app
targets have no unit tests; the snapshot images and the manual plan in [TESTING.md](../../TESTING.md) cover them.

## Extension points

### Recognize another meeting app

Add an entry to `MeetingApp.known` in `Sources/TapeloopIntelligence/MeetingApps.swift`:

```swift
MeetingApp(name: "Jitsi", bundleIDs: ["org.jitsi.jitsi-meet"]),
```

- `bundleIDs`: the first one is the app's id. A process whose bundle ID equals one of them, or starts with one of
  them followed by a dot (helpers such as `com.google.Chrome.helper`), counts as the app. Matching ignores case.
- `extraPrefixes`: other bundle-ID prefixes whose processes count, for example `com.apple.WebKit.` for Safari.
- `kind: .browser` for browsers.

Find an app's bundle IDs while it is in a call: watch the `meetings` log category, or list Core Audio process
objects. `testKnownAppsAreWellFormed` checks the list. Also update the help text of the Meetings tab in
`SettingsView.swift`, which lists app names by hand.

### Add a transcription engine

Implement `Transcriber` (in `TapeloopIntelligence`):

```swift
public protocol Transcriber: Sendable {
    func transcribe(fileURL: URL, locale: Locale) async throws -> [TranscriptSegment]
}
```

Return segments in time order with times in seconds from the file's start and `speaker` `nil`;
`TranscriptionService` adds offsets and You/System labels. Throw an error with a plain-English description for
expected failures and `CancellationError` on cancellation. `SegmentBuilder.segments(from:)` groups timed words into
lines, as both shipped engines do. `ParakeetTranscriber` in `Sources/TapeloopParakeet/ParakeetEngine.swift` is a
complete example.

To offer it in the app:

1. Add a case to `TranscriptionEngine` in `Sources/TapeloopCore/AppSettings.swift`.
2. Choose your transcriber in `Intelligence.transcribe` and say what blocks it in `Intelligence.transcriptionBlocker`
   (`Sources/Tapeloop/Intelligence.swift`); `Windows.transcribeFromLibrary` handles the Library's **Transcribe**.
3. Add it to the Engine control and its help text in the Transcripts tab (`SettingsView.swift`), with sample data
   for the snapshots.

The engine must run on the Mac. If it needs a model file, give `ModelStore` a `TranscriptionModel` catalog entry
(hosted on Tapeloop's own release) instead of writing new download code: CI fails on network APIs outside
`ModelDownloader.swift`, and the privacy promise allows no other network use. A new model's licence goes in
`THIRD_PARTY_NOTICES.md`.

### Update transcribe.cpp

transcribe.cpp is vendored in `ThirdParty/TranscribeCpp` so the build downloads nothing: `CTranscribe.xcframework`
(its prebuilt library, only the universal macOS slice, Metal) is a path-based `binaryTarget`, and `Sources/` is its
Swift wrapper, copied unchanged. To move to a new version, follow
[ThirdParty/TranscribeCpp/README.md](../../../ThirdParty/TranscribeCpp/README.md): replace both from the new
version, keep only the `macos-arm64_x86_64` library in the xcframework and its `Info.plist` entry, build, and run
`swift test --filter TapeloopParakeetTests` with the model installed. Then update the version in
`THIRD_PARTY_NOTICES.md` and check the licence files inside the xcframework. A new version may need a new model
file; if so, publish it as below and change the catalog entry.

### Publish the speech model (maintainers)

The app downloads the model from the `models-v1` release of `harshaxnim/tapeloop`. The catalog entry is
`TranscriptionModel.parakeetUnifiedEnglish` in `Sources/TapeloopCore/TranscriptionModel.swift`: file
`parakeet-unified-en-0.6b-Q8_0.gguf`, 731 357 568 bytes, its SHA-256, and the release URL. To publish it, with the
`gh` CLI signed in to an account that can write releases:

```sh
scripts/publish-model.sh path/to/parakeet-unified-en-0.6b-Q8_0.gguf
```

The script downloads nothing. It checks the file name and the SHA-256, creates the `models-v1` release (not marked
latest) if it does not exist, and uploads the file, replacing an asset of the same name. Run it once per model. To
ship a different model, add a catalog entry with its exact size, SHA-256 and release URL, publish the file, and
update `THIRD_PARTY_NOTICES.md`; an app with the old entry keeps working because the old asset stays.

### Add a transcript export format

Add a function to `TranscriptFormatter` in `TapeloopCore` (pure and testable on Linux, with a test in
`TranscriptFormatterTests`), then a case to `TranscriptExportFormat` in `Sources/TapeloopUI/Library/LibraryModel.swift`
(extension, menu title, content type) and a branch in `LibraryModel.exportTranscript`.

### Add an audio export format

`Exporter.save` chooses between `M4AWriter` (passthrough) and `Mixer` (decode, sum, encode). Add a writer beside
them in `TapeloopExport`, a field to `ExportRequest` to choose it, and a test in `ExportTests`. The chunks hold AAC
packets, so a non-AAC format needs a decode step like `Mixer`'s `SourceReader`.

### Add an audio source

Conform to `AudioSource` (`kind`, `start(onBuffer:onEvent:)`, `stop()`); deliver PCM with the wall-clock time of
the first sample, and report device changes as `SourceEvent.restarted`. Sources are keyed by `SourceKind`, which
has two cases (`microphone`, `system`), so a third source needs a new case, a default in
`RecorderEngine.defaultSource`, a timeline lane in `AppController.makePopoverState`, a Settings row, and a speaker
name in `TranscriptFormatter`.

### Change the UI

Views live in `TapeloopUI` and must not import the audio or intelligence modules. Give a view its data as plain
values (like `PopoverState`) or through `SettingsServices`, add sample data in `Samples.swift` or
`LibrarySample.swift`, and add it to `TapeloopSnapshots/main.swift`. Note that AppKit-backed `Picker` and `Menu`
controls draw as placeholders in `ImageRenderer` snapshots; the Library uses `HostedSnapshot` instead.

## Known limits

- **System audio permission:** no public query exists. The app infers "allowed" once system audio carried sound
  (`systemAudioHeard`), so a silent Mac shows "Asked" even when allowed.
- **Unverified mappings:** FaceTime (`com.apple.avconferenced`) and Firefox (`org.mozilla.plugincontainer`) have
  not been seen in a real call. Any WebKit-based app in a call is reported as "Safari call".
- **Transcription:** Parakeet is English only. Live mode keeps the model loaded (about 0.8 GB) while recording and
  only covers audio recorded after it started; earlier spans fall back to after-save transcription. A failed
  automatic transcription because the model is missing is only logged, not shown. With the Apple engine,
  quality depends on Apple's on-device models and 55-second pieces may split a word. A mixed file transcribed
  later from the Library has no speaker labels.
- **Mixing** re-encodes once at a fixed 64 kbps mono, whatever the buffer's bit rate.
- **Excluded apps:** while the list is not empty, every app launch rebuilds the system audio tap, which can leave a
  short gap.
- **Signing:** releases are ad-hoc signed unless the Developer ID secrets are set, so macOS asks for permissions
  again after each update.
- **Unused code:** `CalendarProvider.eventsEnded` and the `meetingSaved` and `permissionLost` notifications exist
  in code but are not used by the app. Tapeloop offers to save detected meetings, not calendar events.

## Release

1. Run the manual test plan in [TESTING.md](../../TESTING.md#3-manual-test-plan-for-a-release) on a build from the
   release commit. Check that the `models-v1` release still has the model file, since released apps download it
   from there.
2. Move the "Unreleased" entries in [CHANGELOG.md](../../../CHANGELOG.md) under the new version and date, and
   update the compare links at the bottom.
3. Tag and push on `main`:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. CI (`.github/workflows/ci.yml`) runs the Linux core tests and the full macOS job. On a `v*` tag, the app's
   `CFBundleShortVersionString` comes from the tag (without the `v`) and `CFBundleVersion` from the run number.
   Signing and notarization use the repository secrets when present (see [CONTRIBUTING.md](../../../CONTRIBUTING.md)).
5. The `release` job downloads the `Tapeloop-dmg` artifact and runs
   `gh release create <tag> dist/* --generate-notes`, titled "Tapeloop <tag>". Tags with a hyphen
   (`v0.2.0-rc1`) become pre-releases.
6. Check the release page: the DMG and its `.sha256`, then install it on a clean Mac.

Local builds take the version from `VERSION` (default `0.1.0`) and `BUILD_NUMBER` (default `1`):
`VERSION=0.1.1 make dmg`.
