# Tapeloop architecture

Tapeloop keeps a rolling buffer of microphone and system audio, compressed to AAC, in memory. A save copies a span
of that buffer to an `.m4a` file. This document describes the code as of v0.1.0. The original design notes and step
plan are in [PLAN.md](PLAN.md); where the two differ, this document and the code are right.

## 1. Modules

```
                         ┌──────────────────┐
                         │   TapeloopCore   │  pure Swift, builds and tests on Linux
                         └────────▲─────────┘
        ┌───────────────┬─────────┼──────────┬──────────────────────┐
┌───────┴──────┐ ┌──────┴───────┐ │ ┌────────┴────────────┐ ┌───────┴──────┐
│TapeloopAudio │ │TapeloopExport│ │ │TapeloopIntelligence │ │  TapeloopUI  │
└───────▲──────┘ └──────▲───────┘ │ └────────▲────────────┘ └──▲────────▲──┘
        └───────────────┴─────────┼──────────┴─────────────────┘        │
                          ┌───────┴──────┐                     ┌────────┴──────────┐
                          │   Tapeloop   │  the app            │ TapeloopSnapshots │
                          └──────────────┘                     └───────────────────┘
```

On macOS the app also depends on the Parakeet module, which brings in transcribe.cpp:

```
Tapeloop ──► TapeloopParakeet ──► TranscribeCpp ──────────► CTranscribe
                    │             (Swift wrapper, vendored    (transcribe.cpp v0.4.2 xcframework, vendored;
                    ▼              in ThirdParty/)             universal macOS library, Metal)
     TapeloopIntelligence, TapeloopCore
```

Every module depends on `TapeloopCore`. The app target `Tapeloop` depends on all six libraries. `TapeloopAudio`,
`TapeloopExport`, `TapeloopIntelligence` and `TapeloopUI` do not depend on each other; `TapeloopParakeet` depends on
`TapeloopIntelligence` (for the `Transcriber` protocol and `SegmentBuilder`) and on transcribe.cpp. `TapeloopSnapshots`
depends only on `TapeloopCore` and `TapeloopUI`. The macOS-only modules wrap their sources in `#if os(macOS)` so the
package still resolves on Linux.

`Package.swift` declares transcribe.cpp and `TapeloopParakeet` inside `#if os(macOS)`, so Linux never sees them.
Everything is in the repository; the build downloads nothing:

- `CTranscribe` is a path-based `binaryTarget`, `ThirdParty/TranscribeCpp/CTranscribe.xcframework`: transcribe.cpp
  v0.4.2's prebuilt library (13 MB), only its universal macOS slice (arm64 and x86_64), with the Metal backend.
  Its licence files (transcribe.cpp, ggml, miniz, Silero VAD) are inside it.
- `TranscribeCpp` is transcribe.cpp's Swift wrapper, vendored unchanged in `ThirdParty/TranscribeCpp/Sources`
  (Swift 6 language mode; links `c++`, `z`, Accelerate, Metal and MetalKit). How to update both is in
  [ThirdParty/TranscribeCpp/README.md](../ThirdParty/TranscribeCpp/README.md).
- `TapeloopParakeet` and its test target `TapeloopParakeetTests`.

| Module | Main types | Responsibility |
|---|---|---|
| `TapeloopCore` | `EncodedChunk`, `ChunkRing`, `DiskSpillStore`, `SourceBuffer`, `MemoryBudget`, `RecorderSettings`, `AppSettings`, `TranscriptionSettings`, `TranscriptionModel`, `Bookmark`, `RecordingMetadata`, `LibraryStore`, `RecordingName`, `TimeRange`, `TranscriptFormatter`, `TapeloopInfo` | Data models, buffer logic, budgeting, settings and sidecar formats, Library file operations, naming, transcript text and SubRip output |
| `TapeloopAudio` | `AudioSource`, `MicrophoneSource`, `SystemAudioTap`, `AACEncoder`, `CaptureSink`, `RecorderEngine`, `AudioDevices`, `HostClock` | Capture, encoding, the engine that owns the buffers |
| `TapeloopExport` | `Exporter`, `ExportRequest`, `ExportSource`, `M4AWriter`, `Mixer` | Writing a span to `.m4a`: passthrough or mixed |
| `TapeloopIntelligence` | `MeetingDetector`, `MeetingApp`, `CalendarProvider`, `Transcriber`, `SegmentBuilder`, `AppleSpeechTranscriber`, `TranscriptionService`, `IntelligenceError` | Meeting detection, calendar matching, the transcription seam, Apple's on-device transcription |
| `TapeloopParakeet` | `ModelStore`, `ParakeetEngine`, `ParakeetTranscriber`, `LiveTranscriber`, `PCMConverter`, `ParakeetError` | Parakeet transcription through transcribe.cpp: the model file (download, import, verify, delete), after-save and live transcription |
| `TapeloopUI` | `PopoverModel`/`PopoverState`/`PopoverView`, `SettingsModel`/`SettingsServices`/`SettingsView`, `OnboardingModel`/`OnboardingView`, `LibraryModel`/`LibraryView`, `AudioPlayer`, `CassetteIcon`, `Tape` (theme), `Samples` | SwiftUI views and their observable models; no knowledge of the engine |
| `Tapeloop` | `AppDelegate`, `AppController`, `Intelligence`, `Windows`, `MainMenu`, `Services`, `Notifier`, `HotKeys`, `Probe` | Status item, status menu and main menu, wiring, permissions, notifications, shortcuts, the `--probe` mode |
| `TapeloopSnapshots` | `Snapshots` | Renders every screen to PNG from sample data |

## 2. The audio pipeline

```
Microphone ── AVAudioEngine input tap (4096 frames) ─┐
                                                     ├─► CaptureSink.consume ──► AACEncoder ──► EncodedChunk (~5 s)
System audio ─ process tap → private aggregate ──────┘    (one per source,       48 kHz mono      │
               device → IO block                           NSLock)               AAC-LC           ▼
                                                                                          SourceBuffer
                                                                       ┌──────────────────────┴───────────────┐
                                                                       │ ChunkRing (RAM, newest)              │
                                                                       │   ages out ─► DiskSpillStore (opt-in)│
                                                                       │               or dropped             │
                                                                       └──────────────────────┬───────────────┘
                     Save: RecorderEngine.exportPieces (under the lock) ──► detached task ──► Exporter
                           RAM chunks + disk entries                         loads disk part   ├─ one source / per source: M4AWriter (passthrough)
                                                                                               └─ mixed: Mixer (decode, sum, encode once)
```

### 2.1 Capture

- `MicrophoneSource` reads the input device directly with a Core Audio IO block (`HALInput`): the chosen device,
  or the system default when none is chosen or it is not connected. It watches the default input, the device's
  "is alive" property and its sample rate (`AudioPropertyWatcher`); after a burst of changes settles (0.3 s) it
  restarts on the new device or format and reports `SourceEvent.restarted`. A device whose input is not one stream
  of 32-bit floats falls back to a 4096-frame tap on `AVAudioEngine.inputNode`, which restarts on
  `AVAudioEngineConfigurationChange`.
- Both sources ask Core Audio for 4096-frame IO buffers (`IOBufferSize.preferLarge`): about 85 ms per callback at
  48 kHz instead of the default of about 11 ms. Recording does not need low latency, and fewer callbacks mean fewer
  wake-ups. The buffer size is a per-process setting, so other apps' audio is not affected.
- `SystemAudioTap` (macOS 14.2+) creates a `CATapDescription(stereoGlobalTapButExcludeProcesses:)` with the Core
  Audio process objects of excluded apps (an excluded bundle ID also matches its `<id>.` helper processes), wraps
  the tap in a private aggregate device on the default output device, and reads it with an IO block. It needs only
  the System Audio Recording permission (`NSAudioCaptureUsageDescription`). When the default output device changes
  (for example to AirPods), it rebuilds the tap and the aggregate device. When the permission is denied, the tap
  delivers silence rather than an error.
- Each buffer carries the wall-clock time of its first sample, converted from the Core Audio host time by
  `HostClock`.
- The app rebuilds the tap whenever any app launches while the excluded-apps list is not empty, so a newly started
  excluded app is left out too.

### 2.2 Encoding and chunks

`AACEncoder` converts every buffer to 48 kHz mono Float32 (with downmix), tracks a peak level for every 0.5 s, and
encodes to AAC-LC at the chosen bit rate (32, 48, 64 or 96 kbps; default 48 kbps). Raw PCM never outlives one
`consume` call. About every 5 s of packets becomes an `EncodedChunk`: start date, duration, the packets back to
back, a packet size table, and the level peaks.

Chunk times come from capture timestamps. The encoder counts samples from an anchor. When a buffer arrives more
than 0.25 s away from the expected time, it closes the current chunk and re-anchors. That turns pauses, sleep and
device restarts into exact gaps between chunks. `flush()` closes the partial chunk when a source stops.

### 2.3 Buffers and the optional disk part

`SourceBuffer` holds one source:

- `ChunkRing` keeps the newest chunks in RAM and drops chunks older than its length.
- With disk use on, chunks that leave the RAM part go to `DiskSpillStore`: one file per chunk (a little-endian
  header of packet count, frames per packet and packet sizes, then the packets). Only metadata and level peaks
  stay in memory. Chunks older than the whole buffer length are deleted from disk.
- A disk write failure (for example a full disk) records `diskError`, deletes the disk part, and keeps recording
  to RAM.

The disk folder is `~/Library/Caches/io.github.harshaxnim.tapeloop/spill/<source>/`. It is deleted when the engine
starts, when a `DiskSpillStore` is created, when the plan stops spilling, and on quit (`RecorderEngine.wipe`).

### 2.4 Memory budgeting

`MemoryBudget` computes bytes as the sum of the sources' bit rates ÷ 8 × seconds × 1.03 (3 % for packet and level
tables). Two sources at 48 kbps cost 12 360 bytes per second, about 44.5 MB per hour, so the default 2-hour buffer
needs about 89 MB. `testRAMUseForTenMinutes` measures the real figure: 20.0 MB per hour per source at 48 kbps.

`MemoryBudget.plan(requested:allowDisk:)` returns one of:

| Plan | When | Effect |
|---|---|---|
| `.ramOnly(duration)` | the requested length fits under the RAM limit | everything in RAM |
| `.spill(ramDuration, diskDuration)` | it does not fit and disk use is allowed | newest part in RAM, older part on disk |
| `.shortened(to, requested)` | it does not fit and disk use is not allowed | the buffer is cut to what fits |

The RAM limit is 100 MB, 250 MB, 500 MB (default), 1 GB or 2 GB. At the defaults, 500 MB holds about 11 hours of
two 48 kbps sources, so the disk part matters for long custom lengths, high bit rates or a low limit. Settings
asks before it turns on disk use for a length that does not fit.

### 2.5 Memory pressure

`RecorderEngine` listens with `DispatchSource.makeMemoryPressureSource([.warning, .critical])`. On a warning each
source keeps 50 % of its RAM part; on a critical event it keeps 25 %. The oldest chunks go first. With disk use on
they move to disk; otherwise they are lost. The event is logged in category `engine`.

### 2.6 Saving

1. `AppController.save(range:)` asks `RecorderEngine.exportPieces(for:)` for each source's in-RAM chunks and the
   disk entries that overlap the range. This happens under the sink locks and copies no audio from disk.
2. A `Task.detached(priority: .userInitiated)` reads the disk part back (`ExportPieces.loadChunks`, skipping chunks
   that aged out meanwhile) and calls `Exporter.save`.
3. `Exporter` slices each chunk to the range at packet boundaries (about 21 ms), clamps the range to the audio that
   exists, and throws `nothingToSave` when nothing is left.
   - One source, or several with "one file per source": `M4AWriter` writes the AAC packets unchanged with
     `AudioFileWritePackets`. Per-source files get ` - Microphone` or ` - System audio` before `.m4a`.
   - Several sources with "one mixed file": `Mixer` decodes each source one second at a time, aligns them by time
     (gaps become silence), sums and clamps the samples, and encodes once with `AVAudioFile` (AAC, 48 kHz mono,
     64 kbps). A five-hour mix needs a few megabytes of memory.
4. Every file is written under a hidden temporary name (`.tapeloop-<UUID>.m4a`) in the save folder and renamed when
   complete. A taken name gets ` 2`, ` 3`, and so on.
5. Back on the main actor, the controller writes the sidecar metadata (§5), refreshes an open Library, starts
   automatic transcription if it is on (§9), and posts the "Saved" notification.

Progress is reported to the popover in steps of 1 %. **Cancel** cancels the task; the mixer checks for cancellation
between blocks, so a passthrough write runs to the end of the current file.

File names come from `RecordingName.make`: `Tapeloop 2026-11-17 14.05 (15 min) Standup.m4a`. The title part is the
calendar event title, else `<App> meeting`, when the saved span overlaps a detected meeting by at least half of the
shorter of the two.

## 3. Threading

| Where | What runs there | Protection |
|---|---|---|
| Capture queues (the microphone's and the system-audio tap's IO queues, both `.userInitiated` with an autorelease pool per callback) | `CaptureSink.consume`: conversion, encoding, appending chunks, spill writes; in live mode, the PCM observer converts each buffer to 16 kHz and cuts utterances (`LiveTranscriber.consume`) | `CaptureSink`'s `NSLock`; `LiveTranscriber`'s `NSLock` |
| Live transcription queue (serial, `.utility`) | One utterance at a time through `ParakeetEngine` | `ParakeetEngine` serializes all model work with its own `NSLock` |
| Any thread | `RecorderEngine` methods (start, pause, apply settings, status, export pieces) | `RecorderEngine`'s `NSLock`; both classes are `@unchecked Sendable` |
| Main actor | `AppController`, `Intelligence`, `Windows`, `Notifier`, `HotKeys`, every view model (`PopoverModel`, `SettingsModel`, `OnboardingModel`, `LibraryModel`) | `@MainActor` |
| Detached task (`.userInitiated`) | Reading the disk part and writing files during a save | Owns its copies; the engine is not touched |
| Detached task (`.utility`) | After-save transcription; temporary per-source files for speaker labels; loading the Parakeet model when live mode starts; loading the on-device language list (the first time Settings opens) | Results return to the main actor |
| `URLSession` delegate queue | The model download's progress and completion; verifying and moving the file | `ModelStore`'s `NSLock`; state changes hop to the main actor |
| Meeting detector queue | `MeetingDetector` reacts to Core Audio listener calls, and polls every 2 s only while a meeting starts, runs or ends, on a private serial queue (listeners are delivered on a second private queue and hop to it) | Its own `NSLock`; events hop to the main actor with `Task { @MainActor in … }` |
| Global queue | Memory pressure events | Calls into `RecorderEngine` (locked) |
| `WaveformCache` actor | Library waveform peaks, decoded in a detached `.utility` task per file and cached in memory | Actor isolation |

`RecorderEngine.onChange` is always delivered on the main queue. The sink lock is held only for in-memory work and
spill writes, never for reading the disk part back, so a save cannot stall capture. The project builds in Swift 6
language mode with strict concurrency, and CI treats warnings as errors.

## 4. The app and UI layer

- **`AppDelegate`** owns the status item. Left click toggles the popover; right click or Control-click shows the
  menu, which it rebuilds in `menuNeedsUpdate`. Until the welcome guide is finished, a left click reopens the guide
  instead of the popover (its window may be hidden behind other apps). It shows the quit warning: when "Warn me" is on and more than 60 s
  is held, an alert offers **Save Last N and Quit** (N is the held length, at most 30 minutes), **Quit** and
  **Cancel**, with a "Do not ask again" box. `applicationWillTerminate` calls `AppController.shutdown`, which wipes
  RAM and disk.
- **`AppController`** (main actor) is the brain. It owns `RecorderEngine`, `AppSettings` and `PopoverModel`; keeps
  the in-memory bookmarks and meeting spans (both age out with the buffer); suspends capture on
  `willSleep`/`didWake` and, when the setting is on, on `com.apple.screenIsLocked`/`…Unlocked`; saves; handles
  shortcut actions; and builds a fresh `PopoverState` in `refresh()`. It refreshes once per second while the
  popover is open and whenever the engine reports a change.
- **`PopoverState`** is plain data (title, stat, subtitle, banner, `TimelineData`, saving progress). `TimelineData`
  holds the axis, one `Lane` of 120 binned peaks per source, meeting spans, bookmark marks and gaps longer than 8 s.
  The axis length is a "nice" span (5 min, 10 min, … 12 h) that holds the buffered audio. **`PopoverModel`** adds
  the selection (seconds back), the chosen quick span and the pending bookmark label, and calls `PopoverActions`
  closures that the controller supplies. The timeline is one accessibility element ("Rewind timeline") whose
  adjustable action moves the selection by 1 minute.
- **`SettingsModel`** edits a copy of `AppSettings` and passes every change to a closure that calls
  `AppController.update`. That method persists the settings and applies only what changed (recorder settings,
  devices and exclusions, shortcuts, meetings). **`SettingsServices`** is the seam between the UI and the system: a
  struct of closures for permissions, device lists, live levels, launch at login, calendars, languages and so on.
  `Services.make(controller:)` fills it in the app; `Samples.services()` fills it for snapshots.
- **`OnboardingModel`** drives the five-step welcome guide (welcome, microphone, system audio, optional extras,
  done). It uses the same `SettingsServices`, so permission prompts appear in front of a visible window. Step 4
  has a "Transcripts" row with a **Download** button for the Parakeet model (§9.4); nothing is downloaded unless
  the user presses it. Done sets `onboardingDone`, applies the meeting-detection and launch-at-login choices, and
  starts recording.
- **`LibraryModel`** lists the save folder through `LibraryStore`, groups by day, filters by search, plays with
  `AudioPlayer` (rates 1×, 1.25×, 1.5×, 2×), gets waveform peaks from the `WaveformCache` actor, and reloads 300 ms after the folder changes (a `DispatchSource` file-system watcher while the window is
  open).
- **`Windows`** opens Settings, the welcome guide and the Library. Tapeloop starts as an accessory app
  (`LSUIElement`, activation policy `.accessory`: no Dock icon, not in ⌘-Tab). While any of its windows is visible,
  `Windows` switches the activation policy to `.regular`, so the app appears in the Dock and the app switcher and
  shows the main menu that `MainMenu` builds (Tapeloop: About, Settings… ⌘,, Hide, Quit ⌘Q; File: Library ⌘L,
  Close Window ⌘W; Edit: Undo, Redo, Cut, Copy, Paste, Select All; Window: Minimize, Zoom, Bring All to Front).
  When the last window closes, it switches back to `.accessory` and hides itself, which returns the focus to the
  previous app. The services given to the guide and Settings wrap each permission request so that the window is
  brought back to the front after the macOS prompt closes.
- **`Theme.swift`** defines the visual system (`Tape`): flat colours, 3-point corners, one amber accent (#FF9F0A),
  blue for meetings, red for attention. Controls are drawn in SwiftUI so they look the same everywhere and render in
  snapshots.

### 4.1 Settings storage

`AppSettings` (with `RecorderSettings`, `Shortcuts`, `MeetingSettings`, `TranscriptionSettings`) is encoded with
`JSONEncoder` and stored as one data value under the key `appSettings` in the app's defaults domain
`io.github.harshaxnim.tapeloop`. Every field decodes with a default when missing, so older settings still load. An
older key, `recorderSettings`, is read once if `appSettings` is absent. Two Boolean keys support the system audio
permission inference: `systemAudioAsked` and `systemAudioHeard` (§8).

`TranscriptionSettings` stores `enabled`, `engine` (`parakeet` or `apple`), `mode` (`afterSave`, `live` or
`manual`), `localeID` and `labelSpeakers`. The defaults are off, Parakeet, after each save. Settings written before
Parakeet had no `engine` and a Boolean `automatic`; when they are decoded, a stored `enabled` without `engine` means
the Apple engine (that was the only one), and `automatic: false` becomes `manual`. `automatic` is no longer written.

## 5. Sidecar metadata

Recordings stay plain `.m4a` files. What Tapeloop knows about one lives in
`<save folder>/.tapeloop/<audio file name>.json`, for example
`~/Music/Tapeloop/.tapeloop/Tapeloop 2026-11-17 10.48 (36 min) Weekly sync.m4a.json`. `LibraryStore` writes it
atomically, pretty-printed with sorted keys and ISO-8601 UTC dates (with milliseconds only when needed). Missing
optional fields are omitted. This is real output of `LibraryStore.encoder()` for a mixed save from a Zoom meeting:

```json
{
  "bookmarks" : [
    {
      "label" : "decision",
      "offset" : 1420
    }
  ],
  "duration" : 2170.5,
  "meeting" : {
    "appName" : "Zoom",
    "bundleID" : "us.zoom.xos",
    "calendarTitle" : "Weekly sync"
  },
  "mixed" : true,
  "sources" : [
    "microphone",
    "system"
  ],
  "start" : "2026-11-17T09:48:12Z",
  "transcript" : {
    "createdAt" : "2026-11-17T10:25:03Z",
    "locale" : "en-US",
    "segments" : [
      {
        "end" : 754.9,
        "speaker" : "system",
        "start" : 751.2,
        "text" : "Okay, so the release is Friday. Does anyone have blockers?"
      },
      {
        "end" : 785.6,
        "speaker" : "microphone",
        "start" : 782,
        "text" : "Only the onboarding copy. I will send the updated deck tonight."
      }
    ]
  },
  "version" : 1
}
```

| Field | Type | Meaning |
|---|---|---|
| `version` | integer | Format version, 1 |
| `title` | string, optional | A title the user gave in the Library |
| `start` | date | Wall-clock time of the first sample |
| `duration` | seconds | Length |
| `sources` | `["microphone", "system"]` | Sources in this file (one entry for a per-source file) |
| `mixed` | boolean | Several sources mixed into one track |
| `meeting` | object, optional | `appName`, `bundleID`, `calendarTitle` |
| `bookmarks` | array | `offset` (seconds from start) and optional `label` |
| `transcript` | object, optional | `locale`, `createdAt`, `segments` (`start`, `end`, optional `speaker`, `text`) |

The Library title is `title`, else `meeting.calendarTitle`, else the file name. Renaming a recording with metadata
stores the title and renames the file to `Tapeloop <date> (<length>) <title>.m4a`; the sidecar moves with it.
Deleting moves the audio to the Trash and removes the sidecar. A sidecar that cannot be decoded is ignored, and the
recording is shown from its file alone.

## 6. Meeting detection

`MeetingDetector` reads a `CoreAudioProcessProvider`. The provider reads the system object's
`kAudioHardwarePropertyProcessObjectList` (macOS 14.2+), each process's `…BundleID` (cached per process object), and,
for meeting apps only, `kAudioProcessPropertyIsRunningInput` and `…PID`. No permission is needed.

The detector does not poll while nothing happens. It listens for changes to the process list and to "is running
input" of every meeting-app process (`startWatching(on:onChange:)`), and runs its 2-second timer only while a
meeting is starting, ongoing or ending, to time the delays below. A provider that cannot listen (the fakes in the
tests) is polled every 2 s instead. `TapeloopBench watch` checks the listeners on a real Mac.

1. Processes without a bundle ID and Tapeloop's own process are ignored.
2. Each bundle ID is mapped to a `MeetingApp` from `MeetingApp.known`: an exact match first, then a helper prefix
   (`<bundle id>.`, case-insensitive) or one of the app's `extraPrefixes`. Several processes of one app count once;
   two apps are tracked separately.
3. A meeting **starts** once an app's input has run for 5 s without a break. Its start is when the input began.
4. A meeting **ends** once the input has been off for 10 s. Its end is when the input stopped, so muting or
   switching devices for less than 10 s does not split a meeting.
5. When polls are far apart (more than 3 intervals, for example after sleep), a pending start restarts its count and
   an ongoing meeting ends at the last poll that saw input.
6. Turning detection off forgets ongoing meetings without sending `ended` events.

The known apps are Zoom, Microsoft Teams, FaceTime (including `com.apple.avconferenced`), Slack huddle, Webex,
Discord, Skype, WhatsApp, Telegram, Signal, and calls in Chrome, Safari (any `com.apple.WebKit.` process), Arc,
Firefox (`org.mozilla.plugincontainer`), Edge and Brave.

`Intelligence` (in the app) receives events on the main actor, adds the calendar title (§7), and stores the span in
`AppController.meetings`; spans older than the buffer are dropped. When a meeting of at least 60 s ends, it either
saves it (auto-save on) or posts the "meeting ended" notification with **Save meeting** and **Not now** (offer on).

## 7. Calendar

`CalendarProvider` uses EventKit with full access to events (`requestFullAccessToEvents`). For a meeting span it
picks the timed, titled, not cancelled event with the largest overlap, if the overlap is at least half of the
shorter of the two spans or at least 5 minutes; ties go to the event that starts closest to the span. All-day and
untitled events never match. The calendars to use are a list of identifiers; empty means all.
`CalendarProvider.eventsEnded(between:and:calendarIDs:)` exists and is tested but the app does not call it yet.

## 8. Permissions

| Permission | Query | Request |
|---|---|---|
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | `AVCaptureDevice.requestAccess(for: .audio)` |
| System Audio Recording | none public (inferred) | Starting a tap for 2 s makes macOS ask |
| Calendars | `EKEventStore.authorizationStatus(for: .event) == .fullAccess` | `requestFullAccessToEvents()` |
| Speech Recognition (Apple engine only) | `SFSpeechRecognizer.authorizationStatus()` | `SFSpeechRecognizer.requestAuthorization` |
| Notifications | — | `requestAuthorization([.alert, .sound])` before each post |

macOS has no public query for System Audio Recording, and a tap without the permission delivers silence. Tapeloop
therefore records `systemAudioAsked` when it shows the prompt and `systemAudioHeard` once system audio has carried
a level above 0.0005. Settings shows "Asked" until sound is heard, then "Allowed". The popover reports a missing
microphone permission, or a failed source, as a red banner with a button that opens System Settings and, when the
other source is enabled, **Record microphone only** or **Record system audio only**.

## 9. Transcription

Tapeloop has two transcription engines, both on the Mac. The user picks one in Settings › Transcripts
(`TranscriptionSettings.engine`):

| Engine | Module | Languages | Needs | Modes |
|---|---|---|---|---|
| NVIDIA Parakeet through transcribe.cpp (default) | `TapeloopParakeet` | English | The model file (731 MB, downloaded on request) | After each save, live while recording, only when asked |
| Apple speech recognition | `TapeloopIntelligence` | Those with an on-device model | The Speech Recognition permission | After each save, only when asked |

### 9.1 The seam

- `Transcriber` is the engine seam: `transcribe(fileURL:locale:) async throws -> [TranscriptSegment]`, with times in
  seconds from the file's start and no speaker. `ParakeetTranscriber` and `AppleSpeechTranscriber` implement it.
- `SegmentBuilder` groups timed words into lines: a new line after a pause of 0.8 s or more, after a word that ends
  a sentence (`.`, `?`, `!`, `…` and their CJK forms), or when a line would grow beyond 12 s. Both engines use it.
- `TranscriptionService` transcribes one or more parts, shifts each part by its offset, labels each part's lines
  with its source when speaker labels are on, and merges the lines by start time.
- `Intelligence.transcribe` (in the app) picks the transcriber from the settings and runs the service in a detached
  `.utility` task. The Library's **Transcribe** uses the same path with the chosen engine; if transcription is off,
  or Parakeet is chosen and the model is missing, it opens Settings › Transcripts instead; with the Apple engine it
  asks for the Speech Recognition permission first.

### 9.2 Parakeet (after a save, or on request)

- `ParakeetEngine` owns the model. It loads `Model(path:)` and a `Session` from transcribe.cpp on first use and
  keeps them until `unload()`. All work goes through one `NSLock`, so one model serves every caller, one job at a
  time. On an Apple M2 the load takes about 0.2 s, and the loaded model uses about 0.8 GB of memory.
- `ParakeetEngine.readPCM` reads the saved file with `AVAudioFile` and converts it to 16 kHz mono Float32 with
  `PCMConverter` (an `AVAudioConverter` that keeps its state across buffers).
- `transcribe(_:)` feeds the samples to transcribe.cpp's streaming decoder one second (16 000 samples) at a time,
  with word timestamps requested, then finalizes and takes the snapshot. Cancellation is checked between seconds.
  The decoder reports timed tokens (word pieces where a leading space starts a word), so words are rebuilt from
  them and `SegmentBuilder` splits lines as for the Apple engine. If there are no tokens it falls back to the
  decoder's segments, then to its plain text.
- `ParakeetTranscriber` is the `Transcriber`. It ignores the locale (the model is English; transcripts are stored
  with locale `en`) and releases the model after each file, unless live mode is on, in which case the model stays
  loaded for the live transcriber. On an M2, an 8-second clip takes about 1 to 1.5 s including the load.

### 9.3 Live transcription

With Parakeet, mode `live`, transcription on and the model installed, `Intelligence.applyTranscription` creates a
`LiveTranscriber`, loads the model in the background, and sets a PCM observer on `RecorderEngine`. It undoes all of
that (and unloads the model) when any of those conditions stops holding. It is called at launch, after every
settings change and after every model-state change.

```
capture thread ──► PCM observer ──► LiveTranscriber.consume(source, buffer, time)
  (per source)                        │  PCMConverter → 16 kHz mono, per source
                                      │  100 ms RMS windows: voiced, trailing silence
                                      │  cut when ≥ 2 s long and ≥ 0.6 s of pause, at 25 s,
                                      │  or when the next buffer is > 0.5 s off (pause, sleep)
                                      ▼
                        serial worker queue ──► ParakeetEngine.transcribe (shared model)
                                      ▼
                        lines: source, wall-clock start and end, text (in memory)
```

- The observer is called on each source's capture thread with buffers that are valid only during the call, so
  `consume` converts at once and returns. Each source has its own pending piece.
- A window quieter than an RMS of 0.003 (about −50 dBFS) counts as silence. A piece with no voiced window is
  dropped without running the model.
- Lines keep their source and wall-clock times. `AppController.refresh` calls `trimLive(before:)` with the start of
  the buffer, so lines leave memory with the audio they describe. Turning live mode off forgets all lines.
- **A save in live mode.** If live transcription has run for the whole saved span (`covers`: the span starts no
  earlier than 1 s before live mode started), `Intelligence.fromLive` flushes the pending pieces (waits up to
  120 s for the worker), takes the lines that overlap the span, makes their times relative to its start, and writes
  them to the sidecar at once. With one file per source, each file keeps only its own source's lines. Otherwise
  (the span reaches back before live mode started) the save falls back to after-save transcription.

### 9.4 The model store and the network rule

- `TranscriptionModel` (in `TapeloopCore`) is the catalog entry: Parakeet Unified English 0.6B, 8-bit (Q8_0) GGUF,
  file `parakeet-unified-en-0.6b-Q8_0.gguf`, 731 357 568 bytes, a SHA-256, and the URL
  `https://github.com/harshaxnim/tapeloop/releases/download/models-v1/parakeet-unified-en-0.6b-Q8_0.gguf`.
  Maintainers upload it to the `models-v1` release with `scripts/publish-model.sh <file>`, which checks the
  SHA-256 first. Licences are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- `ModelStore` (in `ModelDownloader.swift`) keeps the file in `~/Library/Application Support/Tapeloop/Models`. Its
  state is not installed, downloading (with a fraction), verifying, installed, or failed (with a message for the
  user). The model counts as installed when the file exists with the exact size; the hash is checked when a file
  is installed.
- **Download** runs only when the user presses Download (welcome guide or Settings) or Try Again. It uses an
  ephemeral `URLSession` (60 s request timeout, 6 h resource timeout), reports progress in steps of 0.5 %, and can
  be cancelled. The file is moved to a hidden staging name in the Models folder, a non-200 response is rejected,
  and the size and SHA-256 must match the catalog before the file is moved into place.
- **Import** copies a file the user picks to a staging name and runs the same checks. A wrong file is refused with
  "The file is not the expected model (its size or checksum differs), so it was not used."
- **Delete** removes the file; transcription with Parakeet stops until the model is installed again. Existing
  transcripts are kept.
- When a download or import that the user started finishes, `Intelligence.modelStateChanged` turns transcription
  on with the Parakeet engine. Nothing is downloaded at launch or by default.
- **Network rule.** `ModelDownloader.swift` holds Tapeloop's only network code. CI's "No network code" step fails
  if `URLSession`, `NWConnection`, `URLRequest`, `CFSocket` or `NSStream` appears in any other file under
  `Sources`. The download contacts only GitHub (`github.com`, which redirects to GitHub's release download hosts).

### 9.5 Apple speech recognition

- `AppleSpeechTranscriber` reads the file with `AVAudioFile`, downmixes to mono, and sends pieces of at most 55 s
  to `SFSpeechAudioBufferRecognitionRequest` one after another, with `requiresOnDeviceRecognition = true` and
  punctuation on. It never falls back to the server: a language without an on-device model throws
  `onDeviceUnavailable`. Pieces of digital silence are skipped. Recognizer errors 203 and 1110 ("no speech") count
  as an empty piece.
- It has no live mode. Settings offers only "After each save" and "Only when I ask" for it; a stored `live` mode
  behaves as after each save.

### 9.6 After a save

`Intelligence.recordingSaved` runs when transcription is on, the mode is not `manual`, and the chosen engine can
run (the Parakeet model is installed, or the Speech Recognition permission is given for the Apple engine).

1. Live mode with live lines covering the span: the transcript comes from the live lines (§9.3).
2. **Speaker labels.** After a mixed save with both sources and labels on, `Intelligence` first writes temporary
   per-source passthrough files (in `$TMPDIR/tapeloop-transcribe-<UUID>/`) from the same chunks, transcribes each as
   You (microphone) or System, and deletes them.
3. A per-source save transcribes each file with its own label. A transcription started from the Library on a mixed
   file has no labels, because the separate sources are no longer available.

The result is written into the sidecar, and a "Transcript ready" notification shows the word count.

`TranscriptFormatter` exports `.txt` (`[mm:ss] You: text`, with the title first) and `.srt` (numbered cues,
`HH:MM:SS,mmm` times, speaker before the text).

## 10. Notifications and shortcuts

- `Notifier` uses `UNUserNotificationCenter` and is its delegate, so banners also show while Tapeloop is active.
  Categories: **saved** (Play, Show in Finder), **meeting** (Save meeting, Not now), **transcript** (Open), and plain
  messages (save failed, nothing to save yet, bookmarked, could not transcribe). Responses are routed to the app
  delegate: Play opens the Library at the file and plays it. `meetingSaved` and `permissionLost` messages and a
  **permission** category exist but are not posted yet.
- `HotKeys` registers the shortcuts with Carbon `RegisterEventHotKey` (signature `TPLP`), which needs no
  Accessibility permission. A combination another app holds fails to register; Settings shows that. While a
  shortcut is being recorded in Settings, all shortcuts are unregistered. Defaults: ⌃⌥S save the last
  `shortcutSaveMinutes` (5), ⌃⌥B bookmark (posts a "Bookmarked" notification), ⌃⌥P pause or resume; "open the
  popover" has no default.

## 11. Launch at login

`SMAppService.mainApp.register()` / `unregister()`. The welcome guide's "Open Tapeloop when I log in" box is on by
default the first time. If registration fails, Settings shows a message that suggests moving Tapeloop to the
Applications folder.

## 12. Logging

`os.Logger` with subsystem `io.github.harshaxnim.tapeloop`. Categories: `app`, `engine`, `mic`, `system-audio`,
`encoder`, `meetings`, `calendar`, `transcription`, `intelligence`, `models` (model download, import and install),
`parakeet` (model load and unload), `live-transcription`, `hotkeys`, `services`, `library`, `library-player`,
`probe`.

```sh
/usr/bin/log show --info --last 1h --predicate 'subsystem == "io.github.harshaxnim.tapeloop"'
```

## 13. The snapshot tool

`swift run TapeloopSnapshots <folder> [name-filter]` (or `make snapshots`) renders every screen from the sample data
in `Samples.swift` and `LibrarySample.swift`, in light and dark, at 2× scale:

- `popover-<state>`: recording, just-started, paused, needs-permission, meeting, saving, disk;
- `menubar-icons`: the three icon states at real size and magnified;
- `settings-<tab>`: all eight tabs, plus `settings-transcripts-not-installed` and `settings-transcripts-installed`
  (the speech model before and after the download);
- `library`, `library-search`, `library-transcribing`, `library-empty`;
- `onboarding-1` to `onboarding-5`.

Most views render with `ImageRenderer`. The Library renders through an off-screen `NSHostingView`
(`HostedSnapshot`), because scroll views and text fields do not draw in `ImageRenderer`. AppKit-backed `Picker` and
`Menu` controls still draw as placeholders in the `ImageRenderer` images (visible in the Recording and Memory
tabs). CI uploads the images as the `ui-snapshots` artifact.

## 14. The probe

`Tapeloop --probe --seconds N --out <folder>` (`make probe`) records the microphone and the system audio through the
app bundle, so macOS asks for the app's own permissions; it keeps them encoded in RAM, writes
`probe-microphone.m4a`, `probe-system.m4a` and `report.txt`, and exits non-zero unless the report ends in
`RESULT: OK`. `Tapeloop --version` prints the version; `verify-dmg.sh` uses it.
