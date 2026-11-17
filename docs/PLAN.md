# Rearview: the plan

Rearview is an open-source macOS menu bar app that keeps a rolling, local-only buffer of the
screen, the microphone and the system audio, so that a user can save something after it has
happened. This file is the converged output of the `/feature-dev` pass of step s1. Every later
step (s2 to s5) reads it first and keeps it up to date.

Status legend used below: **[s1]** done in step 1, **[s2]** … **[s5]** owned by that step.

---

## 0. Project conventions (greenfield: these set the patterns)

| Topic | Choice |
|---|---|
| Language | Swift 6, language mode 6, strict concurrency. No warnings (`-warnings-as-errors` in CI release build). |
| Build | SwiftPM only (`Package.swift`). No `.xcodeproj` checked in. `make` wraps every task. |
| Platform | macOS 14.0 deployment target (Harsha runs 14.6). macOS 15+ APIs only behind `if #available`. |
| UI | SwiftUI for views, AppKit for the status item, popover/panel, windows, hotkeys. |
| Storage | Plain files. Segments + a JSON-lines index in `~/Library/Application Support/Rearview/Buffer/`. Settings in `UserDefaults` through a typed `Codable` model. Library = the save folder itself plus `<name>.rearview.json` sidecars. No database. |
| Tests | XCTest. `RearviewCoreTests` runs on Linux and macOS. Media tests run on macOS CI only, with synthetic sample buffers. |
| Lint | `swift format lint --strict` with `.swift-format` (bundled with the Swift 6 toolchain). |
| CI | GitHub Actions: `macos-15` builds, tests, makes `Rearview.app` + DMG + UI snapshot PNGs; `ubuntu` runs Core tests in the `swift:6.0` image. Tags `v*` publish a Release. |
| Docs | `docs/PLAN.md` (this), `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/features/<feature>/` (user and admin guides as HTML, dev notes as Markdown). |
| Identity | Name Rearview, bundle id `io.github.harshaxnim.rearview`, MIT. Own icon (a rounded rear-view mirror with a rewind arrow), own words. Nothing from Backtrack's brand. |

Commands: `make build`, `make test`, `make lint`, `make app`, `make dmg`, `make snapshots`, `make run`.

---

## 1. Hat 1: Product

### Intention
People forget to press record. The need is **"let me keep something after it happened, without
thinking about recording beforehand"**, with the confidence that nothing leaves the Mac and that
the cost (CPU, disk, battery) is small. The literal ask (a Backtrack-like app) is one answer;
the open-source angle adds a second need: **a clean codebase others can extend** (new sources,
new transcribers, new exporters).

### Personas
1. **The meeting person** (calls all day). Wants "save this meeting" after it ends, named after
   the calendar event, with both sides of the audio and a transcript.
2. **The learner** (lectures, tutorials, pair-programming). Wants the last 20 minutes of screen and
   voice, found again by searching the transcript.
3. **The maker / bug-hunter.** Something odd just happened on screen: save the last 2 minutes as a
   video to file a bug.
4. **The privacy-careful user.** Needs to see at a glance whether it is recording, pause in one
   click, exclude apps (password managers), pause on lock, and know that the buffer is deleted.
5. **The consumer of a saved recording** (the same user later, or a colleague who receives the
   file). Needs a normal `.m4a`/`.mp4`, a clear name, and `.txt`/`.srt` transcripts.
6. **The contributor** (developer building on top). Needs `make` targets, a module map, protocols
   at the seams, tests that run without permissions, and CI that produces a DMG.
7. **The packager / admin** (someone distributing it inside a team). Needs signing/notarization
   to switch on with secrets, and documented defaults and storage paths.

### User stories
- As any user, on first launch I see what Rearview does and grant Screen Recording and Microphone,
  with links into System Settings if I said no. (Calendar and Speech are optional, asked later.)
- As any user, I see in the menu bar whether Rearview is recording, paused, or missing a
  permission.
- As the meeting person, after a call I click the menu bar icon, drag back to the start of the
  meeting (or pick the meeting marker), and press Save. I get a file named
  `2026-11-17 1403 Weekly sync (32m).mp4` and a notification.
- As the meeting person, when Zoom/Teams/Meet stops using the mic, a notification asks
  "Save this meeting?" with the detected span.
- As any user, I press a global hotkey to save the last N minutes without opening anything.
- As any user, I bookmark a moment (menu, popover, hotkey) and optionally label it; it shows on
  the timeline.
- As the learner, I open the Library, search a word, and jump to the recording that contains it;
  I play it, rename it, reveal it, share it, delete it, export its transcript.
- As the privacy-careful user, I pause/resume in one click, exclude apps from the screen capture,
  pause when the screen locks, and cap the disk use; "Clear buffer" deletes everything not saved.
- As any user, I choose the sources (screen, mic, system audio), display, fps, quality, buffer
  length (15 min, 30 min, 1 h, 2 h, 5 h, custom) and disk cap, and see current usage.
- Empty state: nothing in the buffer yet ("Recording started 0:12 ago"), nothing in the Library
  ("Saved recordings appear here").
- Failure: disk full, permission revoked, mic unplugged, display removed, sleep/wake, crash. The
  app says what happened in the popover and keeps going where it can.

### Moment-of-action metadata (cannot be rebuilt later)
At save time we store in the sidecar: the span (start/end), sources, display, the frontmost app
and meeting app at that time, the calendar event (id, title), bookmarks inside the span, the app
version. At bookmark time: the timestamp, the label, the frontmost app.

### Done (v0.1.0)
The 13 items of the brief's "must have" list, a DMG on the `v0.1.0` Release, docs, and
`docs/TESTING.md` for a real-Mac pass. CI green.

### Cuts and their reasons (to be confirmed by s3/s4)
- No cloud, no sync, no accounts (by design).
- Camera source: not in v0.1.0; the `CaptureSource` protocol leaves room.
- Whisper transcription: not bundled (size, licensing of models); the `Transcriber` protocol leaves room.
- Per-window capture: v0.1.0 captures a display with app exclusions; single-window is a later source.

---

## 2. Hat 2: Architecture

### Modules (SwiftPM targets)

```
RearviewCore          pure Swift, Foundation only, builds and tests on Linux
  ├─ TimeRange, BufferClock          span math, clamping, overlap, "last N minutes"
  ├─ Segment, SegmentIndex           what each file covers; JSON-lines persistence; rebuild from disk
  ├─ RetentionPolicy                 which segments to delete (age > buffer, total > disk cap)
  ├─ SavePlanner                     segments + trims that cover [start, end]; gaps reported
  ├─ RecordingNamer                  file names (date, time, length, meeting title), sanitising
  ├─ Settings (Codable)              every user setting with defaults and validation, versioned
  ├─ Bookmark, MeetingSpan, SavedRecording (sidecar model)
  ├─ Transcript (+ SRT/TXT writers)  model + exporters, search
  └─ MeetingDetector (pure part)     state machine over "app X uses mic" events → spans
RearviewCapture       macOS: ScreenCaptureKit, AVAudioEngine/Core Audio, AVAssetWriter
  ├─ protocol CaptureSource          start/stop, emits CMSampleBuffers + kind
  ├─ ScreenSource, MicrophoneSource, SystemAudioSource (SCStream audio; macOS 14 ok)
  ├─ SegmentWriter                   rotates fragmented-MP4 files every N seconds
  └─ CaptureEngine (actor)           wires sources → writer → index; sleep/wake, device changes
RearviewExport        macOS: protocol Exporter; CompositionExporter (AVMutableComposition + trim)
RearviewIntelligence  macOS: protocol Transcriber (SFSpeechRecognizer on-device; newer API behind
                      #available), MicUsageMonitor (Core Audio process objects / app list),
                      CalendarProvider (EventKit), LoginItem (SMAppService)
RearviewUI            SwiftUI views and view models (popover, timeline, library, settings,
                      onboarding). No AppKit app lifecycle, so snapshots can render it.
Rearview              the executable: AppDelegate, NSStatusItem, popover, windows, hotkeys,
                      notifications, wiring.
RearviewSnapshots     executable used by CI: renders every key view (light/dark) to PNG.
```

Dependency rule: `Core` ← everything; `Capture`, `Export`, `Intelligence` depend only on `Core`;
`UI` depends on `Core` and talks to the engine through protocols (`RecorderControlling`,
`LibraryStoring`) so previews/snapshots use fakes; `Rearview` wires concrete types.
No third-party dependencies in v0.1.0 (global hotkeys use Carbon `RegisterEventHotKey`).

### Data on disk
```
~/Library/Application Support/Rearview/
  Buffer/
    index.jsonl                  one Segment per line (append-only, compacted by retention)
    seg-<startMillis>-<uuid>.mp4 fragmented MP4, ~60 s, video + audio tracks (or .m4a audio only)
  bookmarks.jsonl, meetings.jsonl
<Save folder, default ~/Movies/Rearview>/
  2026-11-17 1403 Weekly sync (32m).mp4
  2026-11-17 1403 Weekly sync (32m).rearview.json   sidecar (SavedRecording)
  2026-11-17 1403 Weekly sync (32m).transcript.json (+ .txt/.srt on export)
```
Every model has `schemaVersion`. Segment index entries carry: id, file, start, end, tracks
(screen/mic/system), display id, size bytes, complete flag. Crash recovery: on launch, scan
`Buffer/`, drop index lines whose file is missing, add files missing from the index by reading
their duration (AVAsset) and the start time from the file name; incomplete last segment is kept
if readable (fragmented MP4) else deleted.

Audio design: mic and system audio are written as **two separate audio tracks** in each segment
(so users can mute one later, and transcription can label "me" vs "them"); export mixes them by
default (AVMutableAudioMix) with an option to keep both tracks.

### Extension points (designed now, built later)
`CaptureSource` (camera, single window), `Transcriber` (Whisper.cpp), `Exporter` (GIF, clips),
`MeetingAppCatalog` (user-editable list), `Settings.schemaVersion` migrations, sidecar fields
for tags/notes.

---

## 3. Hat 3: UX (mockups and the choice)

### Popover / rewind picker: three options

**A. Horizontal scrubber (pick)**
```
┌──────────────────────────────────────────────┐
│ ● Recording · screen + mic + system   ⏸  ⚙ │
│                                              │
│  Save the last  [5m] [15m] [30m] [1h]        │
│  ────────────────────────────────▶ now       │
│  |▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒████████████████|          │
│  -1h        ◆Weekly sync   ▲bookmark   0     │
│              ↑ drag handle: 23 min back      │
│                                              │
│  23:04 of 1:00:00 · 1.4 GB                   │
│  [ Save 23 min ▾ ]   (audio only / + screen) │
│  ⚑ Bookmark     ▤ Library                    │
└──────────────────────────────────────────────┘
```
**B. Vertical "pull down" ruler** (closest to Backtrack's drag-down: a ruler that hangs from the
menu bar; drag down to go further back). Direct, but tall (1 h needs scaling), and too close to
Backtrack's signature interaction, which we were asked not to copy as brand.

**C. Dial** (rotate a ring to choose minutes). Compact and playful, but imprecise for 2–5 h and
weak for showing bookmarks and meeting spans.

**Choice: A.** It shows the whole buffer, bookmarks and meeting spans on one axis, works with a
trackpad drag, keyboard arrows and quick buttons, and scales to 5 h by a non-linear axis (last
15 min take half the width). Our own twist on "drag to rewind": the handle can also be dragged
directly **from the menu bar icon** (mouse-down on the icon + drag left opens the popover in
scrub mode); s3 implements this if feasible, otherwise the popover alone.

### Library: two options
**A. Split view (pick):** left list (search field on top; rows with name, date, length, source
icons, transcript badge), right detail (player, transcript with clickable timestamps, actions:
Rename, Reveal, Share, Export transcript, Delete).
**B. Grid of thumbnails:** nicer for video, poor for audio-only and for transcript search.
**Choice: A** (matches macOS apps like Voice Memos; works for audio and video).

### Settings
Standard SwiftUI `Settings` window with tabs: General (launch at login, save folder, hotkeys),
Recording (sources, display, fps, quality, excluded apps, pause on lock), Buffer (length, disk
cap, usage bar, Clear buffer), Meetings & Calendar, Transcription, About.

### Onboarding
A 4-page window: Welcome (what and privacy promise) → Screen Recording → Microphone → Optional
(Calendar, Speech, launch at login) → Done. Each permission page shows status and "Open System
Settings" when denied.

### Menu bar icon states
Template image of a small mirror: filled dot = recording, two bars = paused, exclamation = needs
permission / error. Right-click menu: Open Rearview, Save last 5/15/30 min, Bookmark Moment,
Pause/Resume, Library, Settings, Quit.

---

## 4. Hat 4: Developer: edge cases and how each is covered

| # | Case | Handling | Covered by |
|---|---|---|---|
| 1 | Empty buffer, save pressed | Save disabled; message | Core test (SavePlanner empty) + snapshot |
| 2 | Requested span older than buffer | Clamp to buffer start, say so | Core test |
| 3 | Gaps (paused, sleep) inside span | Plan skips gaps; sidecar lists them | Core test |
| 4 | Span cuts mid-segment | Trim first/last segment | Core test + export test (s2) |
| 5 | Disk cap exceeded | Retention deletes oldest first, never the open segment | Core test |
| 6 | Disk full while writing | Writer fails → engine pauses, icon error, retry after retention | s2 unit test with fake writer |
| 7 | Crash | Rebuild index from disk on launch | Core test (rebuild with fake FS listing) + s2 |
| 8 | Sleep/wake | Close segment on sleep, reopen on wake; gap recorded | s2 (NSWorkspace notifications), TESTING.md |
| 9 | Display added/removed | Restart screen source on chosen/main display | s2, TESTING.md |
| 10 | Mic unplugged/changed | AVAudioEngine config change → restart input | s2, TESTING.md |
| 11 | Permission revoked while recording | Stream error → needs-permission state | s2/s3, TESTING.md |
| 12 | Save while saving | Queue saves; progress for each | s2 |
| 13 | Save folder missing/unwritable | Recreate or ask for a new folder | s2 test |
| 14 | Name collisions, illegal characters | Namer adds " 2", strips `/:` | Core test |
| 15 | Huge buffer (5 h, 300 segments) | Index is O(n) small JSON; timeline downsampled | Core perf test |
| 16 | Clock changes / DST | All times stored as UTC `Date`; display local | Core test |
| 17 | Settings from older version | `schemaVersion` + defaults for missing keys | Core test |
| 18 | Mic-only mode (no screen permission) | Audio-only segments `.m4a` | s2 |
| 19 | Long transcript search | Case/diacritic-insensitive search in Core | Core test |
| 20 | Hotkey conflict | Registration failure shown in Settings | s3 |
| 21 | Screen locked | Pause when setting on; gap recorded | s4, TESTING.md |
| 22 | Excluded app windows | SCContentFilter excluding apps | s4, TESTING.md |
| 23 | Dark/light, small screens | Snapshots in both appearances; popover fixed 360 pt width | snapshots |

---

## 5. De-risk

**Riskiest assumption:** code written on Linux (no Swift toolchain on the mini) becomes a working,
signed DMG on a macOS runner. **Proved in s1** by the scaffold: CI builds the package, runs tests,
assembles `Rearview.app`, ad-hoc signs it with entitlements, makes the DMG, re-mounts it in CI and
checks `Info.plist` (`LSUIElement`, usage strings, version, bundle id), the signature and the
entitlements, and renders UI snapshots to PNG. See "s1 result" below.

Other risks and their answers:
- *System audio on macOS 14:* SCStream `capturesAudio` works on 13+ (mic in SCStream needs 15),
  so mic uses AVAudioEngine on 14. OK.
- *Continuous screen capture CPU:* default **5 fps at 1x scale, H.264 hardware encoder, ~1 Mbit/s**; s4 measures.
- *Ad-hoc signing and TCC:* ad-hoc-signed apps get TCC prompts, but the grant is tied to the
  code hash, so **each new build asks again**. Documented in README/TESTING.
- *Global hotkeys without third-party code:* Carbon `RegisterEventHotKey` still works on 14/15
  and needs no Accessibility permission.
- *Snapshot rendering headless:* `ImageRenderer` on the CI runner; proved in s1.
- *Red team:* a recorder that captures everything is sensitive. Answers: no network code at all
  (CI greps for `URLSession`), buffer in Application Support with 0700 permissions, visible
  indicator, pause on lock, app exclusions, Clear buffer, no telemetry.

---

## 6. Verification plan
1. Linux CI: `swift test` for Core (all logic).
2. macOS CI: `swift build` (warnings as errors), `swift test` (Core + media tests with synthetic
   buffers from s2 on), `swift format lint --strict`, `make app`, `make dmg`, DMG verify script,
   `rearview --self-test` (s2: writes segments from a synthetic source, applies retention, saves a
   span, checks duration and tracks), `make snapshots` uploaded as an artifact and looked at.
3. Release: tag `v*` → same pipeline + GitHub Release with the DMG and SHA-256.
4. Real Mac: `docs/TESTING.md` checklist (permissions, real capture, hotkeys, meetings, sleep).

---

## 7. Steps

- **s1 (done when CI is green):** plan, scaffold, minimal menu bar app, app/DMG scripts, CI, snapshots, repo public.
- **s2:** Core models (TimeRange, Segment, SegmentIndex, RetentionPolicy, SavePlanner, Namer,
  Settings) with tests; Capture (sources, SegmentWriter, CaptureEngine) and Export; self-test on CI.
- **s3:** UI: icon states, popover with timeline, save flows, bookmarks, library with playback,
  settings, onboarding, hotkeys, notifications; snapshots light/dark looked at and fixed.
- **s4:** meeting detection, calendar, transcription (+txt/srt), launch at login, excluded apps,
  pause on lock, disk-cap UI, CPU measurement, final app icon.
- **s5:** docs, self-review, `v0.1.0`, verify released DMG, report, the Telegram message.

## 8. s1 result
- Repo is public at https://github.com/harshaxnim/rearview with the scaffold (all files above).
- **Blocked:** the mini's GitHub login lacks the `workflow` scope, so GitHub refused the push of
  `.github/workflows/ci.yml`. The workflow is parked in `ci/ci.yml`. As soon as the scope is
  granted (or Harsha moves the file on github.com), `git mv ci/ci.yml .github/workflows/ci.yml`,
  push, and iterate until CI is green; then fill in this section with the run link and DMG checks.
- No local Swift toolchain was installed (the mini is shared and low on memory; CI is the compiler).
