# Tapeloop: the plan

> **Historical design record.** This is the plan written before v0.1.0. For how the code works now, read
> [ARCHITECTURE.md](ARCHITECTURE.md); for testing, [TESTING.md](TESTING.md). Some details below changed during the
> build (for example the menu bar icon source and the memory figures: two 48 kbps sources need about 43 MB per hour,
> not 78 MB).

Tapeloop is an open-source macOS menu bar app that always keeps the last minutes (up to hours) of the microphone
and the system audio, **compressed, in memory**, so that a user can save a conversation, a call or a lecture after
it happened. Nothing touches the disk until the user saves. This file is the converged output of the `/feature-dev`
pass of step s1. Every later step reads it first and keeps it current.

Status legend: **[s1]** done in step 1; **[s2]** to **[s6]** owned by that step.

---

## 0. Project conventions (greenfield: these set the patterns)

| Topic | Choice |
|---|---|
| Language | Swift 6, language mode 6, strict concurrency. CI builds with `-warnings-as-errors`. |
| Toolchain | Xcode 16.2 / Swift 6.0 (Harsha's Mac). CI pins `Xcode_16.2.app`. No API newer than the macOS 15.2 SDK. |
| Platform | Deployment target macOS 14.0; the process tap needs 14.2 and sits behind `#available`. |
| Build | SwiftPM only. `make build test lint format app dmg verify snapshots run probe clean`. |
| UI | SwiftUI views; AppKit for the status item, popover, menu, windows, hotkeys. |
| Logging | `os.Logger`, subsystem `io.github.harshaxnim.tapeloop`, one category per area (app, mic, system-audio, encoder, probe, …). |
| Style | `.swift-format` (120 columns), enforced in CI (format check + `swift format lint --strict`). |
| Tests | XCTest. Core tests run on Linux and macOS; audio/export tests (synthetic PCM) on macOS only. |
| Art | No binary art in git: icons are SVG sources plus code that draws them. |
| Network | None. CI fails on `URLSession`/`NWConnection`/`URLRequest` in `Sources`. |

---

## 1. Hat 1: Product (why, who, stories)

**Why.** People forget to press record. The useful moment (a promise in a call, a lecturer's aside, an idea in a
brainstorm) is gone by the time they think of it. Tapeloop makes "record" retroactive. Harsha added two constraints
that shape the product: it is **audio only**, and the buffer must live **in RAM, compressed**, touching disk only
past 500 MB and only if the user allows. That makes privacy the default: quit, and it is gone.

**Users.**
- *The recorder* (acts): runs the app all day, saves moments. Sub-types: meeting-goer (calls), student (lectures),
  creator (ideas spoken aloud), support/journalist (interviews; must respect consent laws).
- *The listener* (consumes): replays saved files, reads/searches transcripts, shares a clip. Often the same person
  later, sometimes a colleague who receives a `.m4a`.
- *The privacy-conscious bystander*: wants to see at a glance that recording is on, and to pause it in one click.
- *The builder* (developer): forks the repo, adds a source, an encoder (Opus), a transcriber (Whisper), or a store.
- *The maintainer/admin*: ships releases, signs builds, answers issues; needs CI, docs and a reproducible DMG.

**Stories (v0.1.0).**
1. As a recorder, I see a cassette in the menu bar that tells me whether it is recording. [s1 icon, s3 states live]
2. As a recorder, I save the last 5/15/30/60 minutes with one click, or drag back on a tape timeline to choose. [s2, s3]
3. As a recorder, I bookmark a moment (menu, popover, hotkey) and later save "around this bookmark". [s3]
4. As a meeting-goer, Tapeloop marks my Zoom/Teams/Meet span and offers "Save this meeting?" when it ends. [s4]
5. As a listener, I browse saved recordings, play, scrub, change speed, rename, share, reveal, delete, search. [s3]
6. As a listener, I read and search an on-device transcript; export .txt/.srt. [s4]
7. As a privacy-conscious user, I know nothing is on disk until I save; I can pause, exclude apps, pause on lock. [s3, s4]
8. As a power user, I choose length, bitrate, sources and devices, and see the live RAM use. [s3, s4]
9. As a power user with a long buffer, I may allow disk for the part beyond 500 MB. [s2 engine, s4 UI]
10. As a builder, I read ARCHITECTURE.md and add an `AudioSource` or `Transcriber` without touching the rest. [s1 seams, s5 docs]

**Cuts and deferrals (justified).** No screen recording (Harsha's scope). No cloud/sync (privacy promise). No
auto-upload or sharing service integration beyond the system Share sheet. Whisper transcription is a seam, not a
feature, in v0.1.0 (SFSpeechRecognizer on device is free and built in).

**Consequences users must be told.** The buffer is lost on quit, crash, restart (that is the privacy point). Sleep
pauses capture and the timeline shows the gap. Under memory pressure the buffer shortens instead of the app
crashing. Ad-hoc signed builds may ask for permissions again after each update.

---

## 2. Hat 2: Architecture

### 2.1 Data path

```
 Mic (AVAudioEngine tap)  ─┐                        ┌─ ChunkRing (mic)   ─┐
                           ├─► CaptureSink ─► AACEncoder ─► EncodedChunk ─┤                     ├─► Exporter ─► .m4a
 System (process tap)     ─┘   (lock, per source)   └─ ChunkRing (system)─┘   (passthrough or mix)
                                                         │ over RAM limit + disk allowed
                                                         └─► DiskSpillStore (Caches, wiped on launch/quit) [s2]
```

- PCM lives only inside one `append` call (≈ 85 ms at 4096 frames): it is converted to 48 kHz mono Float32,
  encoded to AAC-LC at 48 kbps (default) and appended as packets to a pending chunk. Each ~5 s of packets becomes an
  `EncodedChunk` (start date, duration, packet bytes back to back, packet sizes).
- **Why AAC-LC, not Opus:** AAC is built into AudioToolbox (no dependency), writes straight into `.m4a` without
  re-encoding, plays everywhere, and is good for speech at 48 kbps. Opus would save ~30 % at speech rates but needs
  a third-party library and an Ogg/CAF container or a transcode on save. The `Encoder` seam keeps Opus possible.
- **RAM model:** bytes ≈ Σ(bitrate)/8 × seconds × (1 + 3 % overhead). Two 48 kbps sources: 21.6 KB/s, 77.8 MB/h,
  216 MB (+3 %) for 5 h. `MemoryBudget` does this arithmetic and plans: RAM only / spill / shortened. [s1]
- **Saving:** pick chunks overlapping [start, end] → `M4AWriter` writes the packets with `AudioFileWritePackets`
  (passthrough; measured in the CI test). "Mix to one track" decodes both, sums with headroom, re-encodes once
  (the only re-encode). "Separate tracks" writes a two-track file with `AVAssetWriter` passthrough. [s2]
- **Timestamps:** chunks carry wall-clock starts; gaps (sleep, pause, device loss) are detected between chunks
  (`ChunkRing.gaps`). s2 replaces the chained `chunkStart` with host-time-derived starts so drift and gaps are exact.

### 2.2 Modules and seams

| Module | Role | Linux |
|---|---|---|
| `TapeloopCore` | `EncodedChunk`, `ChunkRing`, `MemoryBudget`, `TimeRange`, `RecordingName`; later: settings, bookmarks, meetings, spill policy | yes |
| `TapeloopAudio` | `MicrophoneSource`, `SystemAudioTap` (process tap), `AACEncoder`, `CaptureSink`; later the `AudioSource` protocol, SCK fallback, device/sleep handling, `RecorderEngine` actor | no |
| `TapeloopExport` | `M4AWriter` (passthrough); later the mixer and two-track writer behind `Exporter` | no |
| `TapeloopIntelligence` | later: `Transcriber` (SFSpeech), meeting detector, calendar | no |
| `TapeloopUI` | `CassetteIcon`, `RecorderStatus`, `PopoverView`; later timeline, library, settings, onboarding | no |
| `Tapeloop` | the app: status item, menu, `--probe` mode, wiring | no |
| `TapeloopSnapshots` | renders the UI to PNG for CI | no |

Protocols to introduce in s2 (named now so later work lands in the right place): `AudioSource { start(onBuffer:), stop() }`,
`AudioEncoder { append(_:at:) -> [EncodedChunk], flush() }`, `ChunkStore { append, chunks(overlapping:), bytes,
trim }` with `RAMChunkStore` and `SpillingChunkStore`, `Exporter`, `Transcriber`.

### 2.3 Extensibility kept open

New sources (a specific app's audio via a per-process tap; an external interface), new codecs (Opus), new stores
(encrypted RAM, encrypted spill), new transcribers (Whisper), and a future screen buffer would all plug into the
seams above without changing the ring or the UI.

---

## 3. Hat 3: UX (mockups and the pick)

### 3.1 Popover with the rewind timeline: three candidates

**A. "Pull the tape" (picked).** The cassette sits at the top; the tape runs out of it to the left as a horizontal
strip with the level waveform printed on it. "Now" is at the right edge, at the cassette. You grab the strip's left
handle and pull it left (back in time); the selection is the tape that is "out". Bookmarks are small flags on the
tape; meeting spans are tinted bands; gaps are torn/dashed tape. Quick chips under it: 5 · 15 · 30 · 60 min.
One button: "Save 12 min".

```
┌─────────────────────────────────────────────────────┐
│ ● Recording to memory          41 MB · 2 h 00 kept  │
│                                                     │
│  ◀ pull to rewind                         ┌───────┐ │
│ ┄┄┄╱╲╱╲▁▂▅▇▅▂▁▂▃▆▇▆▃▂▁┃▔▔▁▂▅▇▆▄▂▁▂▃▅▃▂▁▁│ ◎   ◎ │ │
│        ⚑ "idea"   [▓▓▓ Zoom ▓▓▓▓▓]  ↑handle  └───────┘ │
│  -40m      -30m      -20m      -10m        now      │
│                                                     │
│  [5 min] [15 min] [30 min] [60 min]   [ Save 12 min ]│
│  ⏸ Pause    ⚑ Bookmark    Library    Settings       │
└─────────────────────────────────────────────────────┘
```

**B. Vertical "drag down" list.** A vertical time ruler; drag a handle downward through the hour. Closest to the
reference app's gesture, but tall, and it reads like a list rather than a tape; weak brand.

**C. Circular reel dial.** Turn a reel to rewind; the angle maps to minutes. Charming, but imprecise for long
buffers (5 h), poor for bookmarks/meeting spans, and hard with a trackpad.

**Pick: A.** It is the most direct gesture (pull back = go back), it shows everything on one axis (level, bookmarks,
meetings, gaps), scales from 15 min to 5 h with a zoomable axis, and is our own brand (tape), not a copy.

### 3.2 Library window: two candidates

**A. Sidebar list + detail (picked).** Left: search field, list grouped by day (name, length, meeting tag).
Right: title (rename inline), waveform scrubber, play/speed, transcript with clickable timestamps, actions
(Share, Reveal, Export transcript, Delete).

```
┌──────────────────────┬──────────────────────────────────────────────┐
│ 🔍 Search            │ Standup  · Tue 17 Nov 14:05 · 15 min          │
│ Today                │ ▁▂▅▇▅▂▁▂▃▆▇▆▃▂▁▂▃▅▇▅▂▁ ━━━━●─────────  1.5× ▶ │
│  ▸ Standup 15 min    │ 00:12  We agreed to ship on Friday…           │
│  ▸ Idea 2 min        │ 00:47  Can you send the deck?                 │
│ Yesterday            │                                              │
│  ▸ Lecture 58 min    │ [Share] [Reveal] [Export .srt] [Delete]       │
└──────────────────────┴──────────────────────────────────────────────┘
```

**B. Grid of cards.** Pretty, but recordings are text-like (names, transcripts); a list scans faster. Rejected.

### 3.3 Menu bar icon

An original cassette outline (template image, `Resources/Icons/cassette-template.svg`, drawn in code by
`CassetteIcon`). States: **recording** = solid dot cut into the top-right corner; **paused** = pause bars between
the reels; **needs attention** = exclamation badge. Rendered at 16/18/22 pt in light and dark by the snapshot job.
The app icon is a warm, full-colour cassette with a red record dot (`Resources/Icons/app-icon.svg`).

### 3.4 Right-click menu

Save Last 5 Minutes · Bookmark Moment · Pause/Resume Recording · Library… · Settings… · Quit Tapeloop. (s1: only
Pause/Resume and Quit are live; the rest are disabled until their step.)

---

## 4. Hat 4: Developer (edge cases and how each is covered)

| Case | Handling | Covered by |
|---|---|---|
| No mic / mic unplugged / default input changes | engine config-change notification → restart source; gap in timeline | s2 test with fake source + Mac test |
| Default output changes (AirPods) | rebuild aggregate device on `kAudioHardwarePropertyDefaultSystemOutputDevice` change | s2 Mac test |
| Mic permission denied | status "needs attention", onboarding deep link | s1 probe reports it; s3 UI |
| System audio permission denied | the tap delivers silence, not an error: detect "all-zero for N s while output is running" and warn | s1 probe warns; s2 detector |
| macOS < 14.2 | no process tap; ScreenCaptureKit audio fallback behind `AudioSource` | s2 (code path), s1 probe reports |
| Sleep/wake | stop on `willSleep`, restart on `didWake`; gap recorded | s2 |
| Memory pressure | `DispatchSource.makeMemoryPressureSource` → trim oldest to 50 % / 25 % | s2 unit test of trim policy |
| Over 500 MB | `MemoryBudget.plan`: shorten (default) or spill (opt-in) | s1 unit tests; s2 spill store tests |
| Disk full while spilling | stop spilling, keep RAM part, warn | s2 test with failing writer |
| Save range partly outside buffer | clamp to the ring's range; empty → disabled button | s1 `TimeRange.clamped`, s3 UI |
| Save while recording continues | snapshot chunks under lock, write off the main thread | s1 `CaptureSink.snapshot`, s2 |
| File name collisions / unsafe titles | `RecordingName.sanitize`, numbered suffix | s1 tests, s2 suffix |
| Very long run (hours) | RAM measured in a long synthetic test | s2 RAM test |
| Concurrency | capture threads → `CaptureSink` lock; UI on main actor; engine actor in s2 | strict concurrency in CI |
| Ad-hoc signature changes | permissions may be asked again; documented | README, s5 |

---

## 5. De-risking (s1)

**Riskiest assumption:** a Core Audio process tap captures system audio on macOS 14.6 built with Xcode 16.2, with
only the System Audio Recording permission. **Proof:** `make probe` runs the real app bundle in `--probe` mode for
10 s: mic + tap at once, AAC in RAM, prints bytes per source and peak level, writes `build/probe/probe-*.m4a`, and
says `RESULT: OK`. CI proves it compiles against the 15.2 SDK; only the Mac can prove it runs (`docs/testing/s1.md`).

**Second risk:** passthrough AAC packets → `.m4a` produce a valid file. **Proof:** `EncodeAndWriteTests` on CI
encodes 10 s of a 440 Hz tone, checks RAM bytes (< 120 KB vs 1.9 MB raw), writes the file, reads it back with
`AVAudioFile`, and checks format, length and that it decodes to the tone.

**Red team.** *"The tap could need the Screen Recording permission on 14.x."* Then the probe shows silence and we
switch the default to the SCK fallback; the seam exists. *"Chained chunk start times drift."* Accepted for s1;
s2 uses host time. *"Ad-hoc signing breaks TCC."* The probe runs through `open` so TCC attributes to the bundle.

---

## 6. Step plan

| Step | Scope |
|---|---|
| s1 | Rename; this plan; core ring/budget/naming; encoder; mic + process tap; passthrough writer; probe; cassette icon; CI green with a verified DMG; `docs/testing/s1.md` |
| s2 | `AudioSource`/`ChunkStore` protocols; `RecorderEngine` actor; disk spill; retention; memory pressure; device changes; sleep/wake; host-time stamps; mixer + two-track export; RAM test; menu "Save Last 5 Minutes" end to end |
| s3 | Icon states live; popover with the "pull the tape" timeline; save flows; bookmarks; library with playback; settings; onboarding; hotkeys; notifications; snapshots of every screen |
| s4 | Meeting detection; calendar; transcription + export; launch at login; pause on lock; per-app exclusion; RAM/disk settings UI; CPU < 3 % |
| s5 | Docs, self-review, `v0.1.0-rc1` pre-release |
| s6 | Final Mac-test fixes, `v0.1.0`, report, the one Telegram message |

## 7. Verification plan

- CI on every push: Linux core tests; macOS format + lint + build (warnings are errors) + all tests + snapshots +
  universal app + DMG + `verify-dmg.sh` (bundle id, `LSUIElement`, usage strings, icon, both slices, signature,
  entitlements, `--version`). Artifacts: DMG, snapshots.
- Every step: `docs/testing/sN.md` for the Mac test; findings come back in the journal and are fixed first.
