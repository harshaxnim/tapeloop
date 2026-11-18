# Changelog

All notable changes to Tapeloop are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-17

The first release.

### Popover

- One mirrored tape (your voice above the line, your Mac's sound below), hairline bars, bookmark icons and meetings
  (with their names) under the tape, and a single ••• menu for Pause, Bookmark, quick spans, Library and Settings.
- **Preview:** the play button on the handle plays the selected span from the handle onwards without saving it.
  Tapeloop leaves its own sound out of the system-audio recording, so a preview (or the Library's player) is not
  recorded.
- **Save only a meeting:** click a meeting under the tape and the selection becomes exactly that meeting.
- **Bookmark a past moment:** under the tape, a bookmark with its time follows the pointer; a click places it.
- **Triple-click** the menu bar icon for Quit.
- **End handle:** a second handle, shown when the pointer nears the right end of the tape, ends the selection before
  now.
- Colour has jobs: red for live (recording, the preview), amber for actions (the handle, Save), grey for the rest.

### Performance

Measured on an M2 MacBook Air while recording both sources (see `docs/TESTING.md` § 1.1 and 1.2).

- About 2 % of one core while recording, no disk writes and about 0.5 wake-ups a second while idle; about 15 MB
  of memory plus the audio held.
- Audio callbacks drain their autorelease pools. Before, every system-audio callback left its buffer object behind
  (about 94 objects a second, over 50 MB an hour: 175 MB after 13 minutes).
- The microphone is read directly from Core Audio instead of through `AVAudioEngine`, and both sources ask for
  85 ms IO buffers instead of 11 ms: about 8 times fewer wake-ups and fewer threads.
- The encoder reuses its buffers and measures levels with vector instructions; finished chunks are stored at their
  exact size (before, a chunk could hold up to twice its size, and memory crept up over hours).
- Meeting detection listens for Core Audio changes instead of polling every 2 s; it polls only while a meeting
  starts, runs or ends.
- The popover's view, the Settings language list (about 60 speech recognizers) and the calendar store are created
  when first needed, not at launch. The Settings and Library windows free their memory when closed. The popover
  timer runs only while the popover is open.
- If the Mac's clock is set back, the buffer stays in order instead of holding audio out of order.

### Added

- **Rolling buffer.** The microphone and the system audio are recorded all the time as two sources, encoded to
  AAC-LC (48 kHz mono, 32 to 96 kbps, default 48 kbps, about 20 MB per hour per source) and kept in memory. The
  length is 15 min, 30 min, 1 h, 2 h (default) or 5 h, or a custom 10 min to 12 h.
- **Memory limit and optional disk use.** A memory limit of 100 MB to 2 GB (default 500 MB). A buffer that does not
  fit is shortened, or, if allowed, its older part is kept in `~/Library/Caches/io.github.harshaxnim.tapeloop/spill`,
  which is erased on quit and on launch. A full disk stops the disk part and keeps recording to memory.
- **Memory pressure handling.** On a macOS memory warning the in-memory part is cut to 50 %, on a critical warning
  to 25 %, oldest audio first.
- **System audio capture** through a Core Audio process tap (macOS 14.2+), which needs the System Audio Recording
  permission but not Screen Recording. It follows output device changes, such as switching to AirPods.
- **Microphone capture** that follows the default input or a chosen device and restarts by itself when a headset
  is plugged in or removed.
- **Excluded apps.** Chosen apps, and their helper processes, are left out of the system audio.
- **Saving.** Save any span as `.m4a` to `~/Music/Tapeloop` (configurable), as one mixed file or one file per
  source. Single-source files are written without re-encoding. Files are named
  `Tapeloop <date> <time> (<length>) <title>.m4a` and never overwrite each other.
- **Popover** with a draggable rewind timeline: You and System level lanes, meeting bands, bookmark flags, gaps,
  quick spans (5 min, 15 min, 30 min, 1 h), save progress with Cancel, and banners for meetings and missing
  permissions. The timeline is adjustable with VoiceOver.
- **Menu bar icon** with recording, paused and needs-attention states, and a right-click menu: save the last
  5/15/30/60 minutes, save the current or last meeting, bookmark, pause or resume, Library, Settings, About, Quit.
- **Bookmarks** with optional labels, kept in saved recordings.
- **Global shortcuts** through Carbon hot keys (no Accessibility permission): ⌃⌥S save the last N minutes,
  ⌃⌥B bookmark, ⌃⌥P pause or resume, and an optional "open the popover" shortcut; all can be changed.
- **Pause** by hand, always while the Mac sleeps, and optionally while the screen is locked. Pauses show as gaps.
- **Notifications** for saves (Play, Show in Finder), ended meetings (Save meeting, Not now), finished transcripts
  (Open), bookmarks from the shortcut, and errors.
- **Quit warning** that offers to save the last 30 minutes (or less) before the buffer is erased.
- **Welcome guide** in five steps that asks for each permission from a visible window and offers launch at login.
- **Settings** in eight tabs: General, Recording, Memory, Shortcuts, Meetings, Transcripts, Privacy, About.
- **Library**: recordings grouped by day, search across titles, file names, meetings, bookmarks and transcripts,
  a player with waveform, bookmarks and 1× to 2× speed, rename, share, show in Finder, delete to the Trash, and
  transcript export as `.txt` or `.srt`. It follows changes to the save folder.
- **Regular-app mode while a window is open.** With the welcome guide, Settings or the Library open, Tapeloop
  appears in the Dock and ⌘-Tab and has a standard main menu; it returns to the menu bar when the last window
  closes.
- **Meeting detection** without any permission: a known call app (Zoom, Microsoft Teams, FaceTime, Slack, Webex,
  Discord, Skype, WhatsApp, Telegram, Signal, and calls in Chrome, Safari, Arc, Firefox, Edge and Brave) that uses
  the microphone for 5 s starts a meeting, which ends 10 s after the input stops. Offer to save, or save
  automatically, when it ends.
- **Calendar titles** (opt-in, EventKit) for meetings and recordings, from chosen calendars.
- **On-device transcription with NVIDIA Parakeet** (opt-in, English) through transcribe.cpp v0.4.2 (MIT). Its
  prebuilt macOS library (universal, Metal) and its Swift wrapper are vendored in `ThirdParty/TranscribeCpp`, so
  the build downloads nothing. The model is Parakeet Unified English 0.6B, 8-bit (Q8_0), 731 MB.
- **Speech model download on request.** The model is downloaded only when the user presses **Download** in the
  welcome guide or Settings › Transcripts, from the `models-v1` release of Tapeloop's own GitHub repository, with
  progress and Cancel, and is installed only if its SHA-256 matches. A file the user already has can be imported
  (it must match too), and the model can be deleted. It is kept in `~/Library/Application Support/Tapeloop/Models`.
  Nothing is downloaded by default; finishing a download the user started turns transcription on with Parakeet.
- **Transcription modes:** after each save (default; the model is loaded for the job and released afterwards), live
  while recording (Parakeet only; the model stays loaded, about 0.8 GB, and a save takes its transcript from the
  live lines at once), or only when asked from the Library.
- **Apple speech recognition** as the second engine (opt-in), with `requiresOnDeviceRecognition`, for languages
  other than English. Settings saved by earlier builds keep the Apple engine.
- **Labelled lines.** Transcript lines are labelled You or System from the two sources.
- **Sidecar metadata** for each recording in `<save folder>/.tapeloop/<file name>.json` (title, meeting, bookmarks,
  transcript).
- **Launch at login** through `SMAppService`.
- **One network call, and only on request.** The speech-model download is the only network code, kept in
  `Sources/TapeloopParakeet/ModelDownloader.swift`. CI fails the build if `URLSession`, `NWConnection`,
  `URLRequest`, `CFSocket` or `NSStream` appears in any other source file.
- **Third-party notices** in `THIRD_PARTY_NOTICES.md` (transcribe.cpp, ggml, miniz, Silero VAD, Parakeet) and a
  line in Settings › About.
- **Developer tooling:** SwiftPM modules (`TapeloopCore` builds and tests on Linux), 103 unit tests, `make probe`,
  a snapshot renderer for every screen in light and dark, and CI that builds a universal, verified DMG and
  publishes it on `v*` tags.

### Known limits

- Parakeet transcribes English only. Use the Apple engine for other languages.

- The System Audio Recording permission cannot be queried, so Tapeloop infers it from hearing sound.
- Meeting mappings for FaceTime and Firefox are not yet verified on real calls.
- Release builds are ad-hoc signed and not notarized, so macOS asks for permissions again after each update.

[Unreleased]: https://github.com/harshaxnim/tapeloop/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/harshaxnim/tapeloop/releases/tag/v0.1.0
