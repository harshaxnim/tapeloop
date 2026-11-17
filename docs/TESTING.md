# Testing Tapeloop

This is the one place for how Tapeloop is tested: the automated tests, what CI runs, and the manual test plan for a
release. The per-step Mac test scripts written during development (for example
[testing/s1.md](testing/s1.md)) are kept as history; this file supersedes them for releases.

## 1. Automated tests

Run them all with `make test` (`swift test`). A full run takes about one minute on an Apple silicon Mac; most of it
is the export tests, which encode and decode real audio. On Linux only the core tests run:
`swift test --filter TapeloopCoreTests`.

All tests are XCTest. The audio and intelligence tests use synthetic PCM, fake audio sources and a fake process
provider, so they need no microphone, no permission and no network. The model-store tests "download" a small local
file through a `file://` URL, so they need no network either.

Two Parakeet tests need the real speech model in `~/Library/Application Support/Tapeloop/Models` and skip themselves
when it is not there, as on CI: `testTranscribesSpeech` and `testLiveLinesCoverASavedSpan`. Both make their speech
with the system `say` voice. To run them, install the model first (Settings › Transcripts › **Download**, or copy the
file into that folder).

Counts from `swift test` on 17 November 2026, with the model installed: **137 tests, 0 failures.** Run
`swift test 2>&1 | grep Executed` for the current total.

### TapeloopCoreTests (53 tests; macOS and Linux)

| Suite | Tests | What it checks |
|---|---:|---|
| `ChunkRingTests` | 5 | Empty ring, dropping by age and by bytes, overlap queries and gaps, `removeAll` |
| `SourceBufferTests` | 10 | Packet-accurate slicing; RAM-only length; spill to disk and read back; loading disk pieces outside the lock; turning spill off deletes the disk part; left-overs wiped on create; damaged files reported; memory pressure frees RAM |
| `RecorderSettingsTests` | 4 | Defaults, old JSON loads with defaults, round trip, a long buffer at a high rate needs disk |
| `MemoryBudgetTests` | 3 | 5 h of two 48 kbps sources is 216 MB; over-limit plans shorten or spill; no sources |
| `LibraryStoreTests` | 14 | Listing (hidden and non-audio files ignored, newest first), derived title/start/end, sidecar path and round trip, old and partial JSON, rename (moves both files, avoids collisions, same name, empty title), delete to Trash with sidecar, day grouping labels, search matching |
| `TimeRangeTests` | 5 | Bound ordering, "last N seconds", intersection, clamping, identity |
| `RecordingNameTests` | 2 | File name format and length labels |
| `TranscriptFormatterTests` | 5 | Timestamps, plain text, SubRip, backwards times clamped, speaker names |
| `TranscriptionSettingsTests` | 5 | Defaults (off, Parakeet, after each save); older settings decode to the Apple engine and `automatic: false` to "only when I ask"; round trip without the old `automatic` key; "only when I ask" is not automatic; the catalog entry (64-character SHA-256, a `github.com` URL ending in the file name, over 700 MB) |

### TapeloopAudioTests (11 tests; macOS)

| Suite | Tests | What it checks |
|---|---:|---|
| `EncodeAndWriteTests` | 1 | 10 s of a 440 Hz tone encodes to a small AAC buffer and writes a valid `.m4a` that decodes back to the tone |
| `ExportTests` | 8 | Gaps become separate segments with exact times; passthrough save trimmed to the range; the mix aligns sources by time and fills gaps with silence; silence where no source has audio; separate files when not mixing; saving twice does not overwrite; nothing to save; RAM use for 10 minutes (prints `RAM: 20.0 MB per hour per source at 48 kbps`) |
| `RecorderEngineTests` | 2 | Recording, pausing and turning sources off with fake sources; a failing source is reported and memory pressure shrinks the buffer |

### TapeloopIntelligenceTests (29 tests; macOS)

| Suite | Tests | What it checks |
|---|---:|---|
| `MeetingDetectorTests` | 12 | Starts after 5 s of input; short blips ignored; ends 10 s after input stops, with the stop time; a mute under 10 s does not split; helper processes map to their app; own process ignored; unknown apps ignored; overlapping apps tracked separately; sleep gaps do not stretch meetings; stop forgets meetings without end events; events reach the handler; the known-app list is well formed |
| `CalendarMatchTests` | 6 | Largest overlap wins; all-day and untitled events ignored; the half-or-5-minutes rule; a just-started meeting matches its event; ties go to the closest start; events ended in a window |
| `TranscriptionTests` | 11 | Line splitting at pauses, sentences and about 12 s; empty text dropped; merge shifts, labels and sorts; the service transcribes every part and passes errors on; missing file is unreadable; unknown locale cannot run on device; on-device locales sorted and supported; a silent file needs permission or gives nothing; error messages are plain English |

### TapeloopParakeetTests (10 tests; macOS)

| Suite | Tests | What it checks |
|---|---:|---|
| `EngineTests` | 2 | transcribe.cpp reports a version; a spoken sentence ("…the release is on Friday… the updated deck tonight") is transcribed with the words "release", "friday" and "deck", valid times, and the model released afterwards (skipped without the model) |
| `ModelStoreTests` | 4 | SHA-256 matches CryptoKit; importing the exact file installs it and delete removes it; importing a different file is refused with "not the expected model"; a download is verified and installed |
| `TokenWordTests` | 2 | Word pieces join into words at leading spaces; a first piece without a space starts a word |
| `LiveTranscriberTests` | 2 | Live lines cover a saved span, carry the source label, are empty after the span and are trimmed (skipped without the model); silence is measured in 100 ms windows |

`TapeloopUITests` drives the real popover in an off-screen window with real mouse and keyboard events (the
timeline drag, the duration chips, Save, Cancel, the label field). The app target itself has no unit tests; it is
covered by the snapshot images, the bench below and the manual plan.

### 1.1 Performance, stress and leak tests (`TapeloopBench`)

`TapeloopBench` is a command-line tool that sends synthetic audio through the real recorder engine, encoder, ring
buffer, disk spill and exporter, much faster than real time. It needs no microphone, permission or network.

```sh
swift build -c release --product TapeloopBench
.build/release/TapeloopBench soak 4            # 4 h of two-source audio into the default 2 h buffer
.build/release/TapeloopBench soak 6 --spill    # 6 h into a 5 h buffer with a 50 MB memory limit, disk beyond
.build/release/TapeloopBench sponge --leaks    # hostile input and concurrent operations, then `leaks` on itself
.build/release/TapeloopBench model 3           # speech model: load, transcribe 43 s of speech, unload, 3 times
.build/release/TapeloopBench watch             # meeting detection's Core Audio listeners see a new audio process
```

Each prints `ok` or `FAIL` per check and ends with `PASS` or `FAILED`; the exit status is 0 only on `PASS`.

- **soak** checks that the buffer holds exactly its length, that the encoded audio stays within its memory budget,
  that process memory levels off within 30 % + 40 MB of the audio held, that saves of 5 minutes, 1 hour and the
  whole buffer produce files of the right length, and that a wipe empties memory and disk. It prints the CPU time
  per hour of audio.
- **sponge** feeds 21 formats (8 to 192 kHz; 1, 2 and 6 channels) into one buffer; empty, one-frame and very large
  buffers; NaN, infinite, beyond-full-scale, DC and silent samples; timestamps that go back, repeat, jump 3 hours,
  or lie far in the future or past (the buffer must stay ordered and within its length); and 200 rounds of
  settings changes, pauses, memory warnings, saves and wipes while audio flows on another thread.
- **model** is skipped when the speech model is not installed.

Results on an M2 MacBook Air (17 November 2026), release build:

| Test | Result |
|---|---|
| Soak, 4 h, two sources, 48 kbps | 24 s of CPU per hour of audio (0.66 % of one core); buffer 88.7 MB; process memory levels off at about 115 MB; saving 2 h takes 0.1 s |
| Soak, 6 h, 50 MB memory limit | Same CPU; 50 MB per source in memory, 59 MB on disk; memory levels off at about 160 MB; saving 5 h takes 1.1 s |
| Sponge | All 19 checks pass; 0 leaks; memory 11 MB above the start afterwards |
| Speech model | First load 30 s (disk and GPU shader compilation), later loads 0.02 s; 43 s of speech in 11 to 14 s; about 83 MB while loaded; about 50 MB of GPU framework caches stay after the first use and do not grow |

### 1.2 Measuring the running app

The app should be close to invisible: no work while idle except encoding, no disk writes, few wake-ups. To measure
it, use the kernel's own accounting (`proc_pid_rusage`), which is what Activity Monitor's figures come from:

```sh
top -l 13 -s 5 -pid $(pgrep -x Tapeloop) -stats pid,cpu,mem,power,threads,idlew   # a minute of samples
sample $(pgrep -x Tapeloop) 10 -file /tmp/tapeloop-sample.txt                          # where the CPU time goes
leaks $(pgrep -x Tapeloop)                                                             # should say 0 leaks
vmmap --summary $(pgrep -x Tapeloop)                                                   # memory by region
```

Measured on the M2 MacBook Air, both sources recording, the popover closed, over 2 minutes:

| Measure | Before the performance work | Now |
|---|---|---|
| CPU | 2.2 % of one core | 1.1 % |
| Memory (physical footprint) | 175 MB after 13 minutes, growing | 13.4 MB, flat |
| Threads | 11 | 8 |
| Wake-ups from idle | not measured | 0.1 a second |
| Disk writes | 0 | 0 |
| Leaks (`leaks`) | about 94 buffer objects a second never freed | 0 |

Most of the remaining CPU time is the AAC encoder itself. The audio held in the buffer comes on top of the 13 MB
(about 22 MB per hour per source at the default quality).

### 1.3 Permissions across rebuilds and updates

macOS stores each permission (microphone, system audio, calendars, speech) against the app's signature. An ad-hoc
signature identifies the app by the hash of its code, so every rebuild, and every update of an ad-hoc release, is a
new app to macOS and the permissions are asked for again. A signature from a fixed certificate identifies the app by
its bundle ID and that certificate, so the permissions stay.

For local builds, run `scripts/dev-signing.sh` once. It creates a self-signed "Tapeloop Local Signing" identity in its
own keychain in `~/.tapeloop-signing` (the login keychain is not touched), and `scripts/sign.sh` then uses it for every
`make app`. `scripts/dev-signing.sh --remove` undoes it.

To check that the permissions stay:

1. `codesign -d -r- build/Tapeloop.app` must show `certificate leaf`, not `cdhash`.
2. Launch the app and grant the microphone and system audio permissions.
3. Quit, rebuild (`make app`) and launch again. No prompt may appear, and the log must show both as authorized:
   `log show --last 2m --info --predicate 'subsystem == "io.github.harshaxnim.tapeloop"' | grep "permission at launch"`.

## 2. What CI runs

`.github/workflows/ci.yml` runs on every push to `main`, every pull request, every `v*` tag and on demand.

1. **Core tests (Linux):** `swift test --filter TapeloopCoreTests` in the `swift:6.0` container. The Parakeet
   targets are declared for macOS only, so Linux never builds them.
2. **macOS (Xcode 16.2, `macos-15` runner):**
   - format check (`swift format --in-place`, then `git diff --exit-code`);
   - `make lint` (`swift format lint --strict`);
   - the network check: the job fails if `URLSession`, `NWConnection`, `URLRequest`, `CFSocket` or `NSStream`
     appears in any file in `Sources` other than `Sources/TapeloopParakeet/ModelDownloader.swift`;
   - `swift build -Xswiftc -warnings-as-errors`;
   - `swift test` (the two tests that need the Parakeet model are skipped);
   - `swift run TapeloopSnapshots build/snapshots`;
   - a universal app (`scripts/make-app.sh`), the DMG (`scripts/make-dmg.sh`) and `scripts/verify-dmg.sh` (bundle
     ID, `LSUIElement`, minimum system 14.0, the four usage descriptions, icon, arm64 and x86_64 slices, signature,
     microphone entitlement, `--version`);
   - artifacts: `Tapeloop-dmg` (DMG and `.sha256`) and `ui-snapshots`.
3. **Release (tags `v*` only):** creates a GitHub Release with the DMG and its checksum (see
   [features/tapeloop/dev.md](features/tapeloop/dev.md#release)).

## 3. Manual test plan for a release

Run this on a real Mac with the release DMG, not a debug build, because permissions belong to the signed app
bundle. Use macOS 14.2 or later; repeat the first-run section on macOS 14.0 or 14.1 if one is available. Mark each
item, and write down anything unexpected with the time, so it can be found in the log:

```sh
/usr/bin/log show --info --last 1h --predicate 'subsystem == "io.github.harshaxnim.tapeloop"'
```

### 3.1 Install and first run

- [ ] Reset earlier decisions so every prompt appears:
      `tccutil reset All io.github.harshaxnim.tapeloop` and `defaults delete io.github.harshaxnim.tapeloop`.
- [ ] Install from the DMG. The first launch is blocked by Gatekeeper; **Open** (macOS 14) or **Open Anyway**
      (macOS 15+) works, and so does `xattr -dr com.apple.quarantine /Applications/Tapeloop.app`.
- [ ] The welcome guide opens with five steps. While it is open, Tapeloop is in the Dock and ⌘-Tab, and the menu
      bar shows the Tapeloop, File, Edit and Window menus.
- [ ] Click another app so the guide goes behind it, then click the menu bar cassette: the guide comes back to the
      front (before setup is finished the cassette never opens the popover).
- [ ] Step 2: **Allow…** shows the macOS microphone prompt. After Allow, the row shows "Allowed" and the guide is
      in front again.
- [ ] Step 3: **Allow…** shows the System Audio Recording prompt. After Allow, the row shows "Asked" (it changes to
      "Allowed" in Settings once system audio has carried sound). Denying shows **Check in System Settings**, which
      opens the Screen & System Audio Recording page.
- [ ] Step 4: Calendar shows its macOS prompt. The Transcripts row shows **Download** and nothing is downloaded
      unless it is pressed (`~/Library/Application Support/Tapeloop/Models` stays empty or absent). The
      meeting-detection switch is on.
- [ ] Step 5 shows the shortcuts and "Open Tapeloop when I log in" (checked). **Done** closes the guide, the menu
      bar icon turns to recording (amber dot), Tapeloop leaves the Dock and ⌘-Tab, and the focus returns to the
      previous app.
- [ ] Settings › General › **Show Welcome Guide Again** reopens the guide.

### 3.2 Popover states

- [ ] **Just started:** "Recording to memory", subtitle "Started at … Keeps up to 2 h …", the stat shows the held
      time and the memory used.
- [ ] **Recording** after 10 minutes: subtitle "Nothing is written to disk until you save."
- [ ] **Paused:** the icon dot turns grey; title "Paused", "Paused at HH:MM. Nothing is being recorded."
- [ ] **Needs permission:** with the microphone denied, the icon shows a red ring and a red banner explains it, with
      **Open System Settings** and **Record system audio only**.
- [ ] **Meeting:** during a call, a blue banner "Zoom meeting · started …" with **Save meeting**.
- [ ] **Saving:** a progress bar with a percentage and **Cancel** appears while a long mixed save runs.
- [ ] **Disk:** with disk use on and audio on disk, the title reads "Recording to memory and disk".

### 3.3 Timeline and saving

- [ ] Dragging the amber handle changes the selection; the tip shows "−N min" and the Save button follows.
- [ ] The handle cannot go past the start of the held audio.
- [ ] Each quick span (5 min, 15 min, 30 min, 1 h) selects that span; chips longer than the held audio are
      disabled (5 min is always enabled once audio is held).
- [ ] **Save** writes `Tapeloop <date> <time> (<length>).m4a` to `~/Music/Tapeloop`. The length is right and both
      sides are audible.
- [ ] The "Saved" notification's **Play** opens the Library at the file and plays it; **Show in Finder** reveals it.
- [ ] With "One file per source", a save writes `… - Microphone.m4a` and `… - System audio.m4a`.
- [ ] Each right-click menu item works: Save Last 5, 15 or 30 Minutes, Save Last Hour, Bookmark Moment, Pause or
      Resume Recording, Library…, Settings…, About Tapeloop, Quit Tapeloop.
- [ ] Saving with nothing held posts "Nothing to save yet".

### 3.4 Bookmarks, pause and gaps

- [ ] **Bookmark** in the popover opens a label field; typing "idea" and Return puts a flag labelled "idea" on the
      timeline. Closing the popover also keeps the label.
- [ ] ⌃⌥B adds a bookmark from another app and posts "Bookmarked HH:MM".
- [ ] A save that includes the bookmark shows it in the Library's player ("Bookmark “idea” at mm:ss").
- [ ] ⌃⌥P pauses; wait one minute; ⌃⌥P resumes. The timeline shows a hatched gap of about one minute.
- [ ] ⌃⌥S saves the last 5 minutes from another app. Change the length in Settings › Shortcuts and repeat.

### 3.5 System events and devices

- [ ] **Sleep and wake:** sleep the Mac for 2 minutes. After wake, recording resumes and the timeline shows the gap.
- [ ] **Lock screen:** with "Pause while the screen is locked" off, locking does not pause. Turn it on, lock for one
      minute, unlock: the popover said recording pauses while locked, and the gap appears.
- [ ] **Headset:** plug in and remove a wired or USB headset while recording. The microphone restarts by itself
      (log: "Input configuration changed; restarting the microphone") and the You lane continues.
- [ ] **Output device:** switch the output to AirPods and back while audio plays. The System lane continues (log:
      "Default output changed; rebuilding the system audio tap").
- [ ] **Chosen microphone:** pick a specific input in Settings › Recording; the You level meter follows it.
- [ ] **Excluded apps:** add Music in Settings › Privacy, play music: the System lane stays flat and saves do not
      contain it. Remove it again: music is recorded.

### 3.6 Memory

- [ ] Settings › Memory shows "used now", the estimate when full and the limit. 2 h at 48 kbps with two sources is
      about 89 MB.
- [ ] Set the limit to 100 MB and choose 5 h: an alert "Turn on disk use?" offers **Use Disk Beyond 100 MB**,
      **Keep … in Memory Only** and **Cancel**. Each choice does what it says, and the note under "Memory use"
      shows the plan.
- [ ] With disk use on and audio beyond the limit, files appear in
      `~/Library/Caches/io.github.harshaxnim.tapeloop/spill/`. A save across the RAM and disk parts is continuous.
      Quitting deletes the folder.
- [ ] **Memory pressure:** run `sudo memory_pressure -S -l warn` (simulates a warning without allocating), then
      `sudo memory_pressure -S -l critical`. The log shows "Memory pressure (warning): buffer shortened" and
      "(critical)", and the held time drops to about half and then a quarter of the RAM part. Restore with
      `sudo memory_pressure -S -l normal`.
- [ ] **Erase Buffer Now…** asks, then empties the buffer; saved recordings are untouched.

### 3.7 Meetings and calendar

- [ ] **Meeting detection:** join a real Zoom, Teams, Meet (in Chrome or Safari) or FaceTime call. After about
      5 seconds a blue band starts on the timeline and the popover shows the meeting banner.
- [ ] End the call. About 10 seconds later the "The … meeting ended" notification appears; **Save meeting** saves
      exactly the call's span, named `… Zoom meeting.m4a` (or the calendar title).
- [ ] With "Save it automatically" on, the meeting is saved without a prompt. Calls under 1 minute never prompt.
- [ ] **Calendar:** with calendar titles on and an event covering the call, the banner shows "<title> (from your
      calendar)" and the file and Library use the event title. Unticking that calendar stops it.

### 3.8 Transcripts

Start without the model: quit Tapeloop, run `rm -rf ~/Library/Application\ Support/Tapeloop/Models`, and open it
again. Watch the log categories `models`, `parakeet`, `live-transcription` and `intelligence`.

**Download**

- [ ] Settings › Transcripts with the Parakeet engine: the Speech model row shows "Parakeet Unified English 0.6B
      (8-bit)", **Download (731 MB)**, **Import File…** and "Downloaded from Tapeloop's GitHub page only when you
      press Download."
- [ ] Before pressing anything, `lsof -nP -i -a -p "$(pgrep -x Tapeloop)"` prints nothing.
- [ ] **Download** shows a progress bar and a percentage that rises. **Cancel** returns to **Download**, and the
      Models folder holds no model file.
- [ ] With Wi-Fi off (and no other network), **Download** fails with a red "The download failed: …" message,
      **Try Again** and **Import File…**. Turn the network on; **Try Again** downloads.
- [ ] At the end the row shows "Checking the downloaded file…", then "Installed 731 MB" and **Delete…**. The
      "Transcribe recordings" switch has turned on with Parakeet. The log shows "Installed
      parakeet-unified-en-0.6b-Q8_0.gguf".
- [ ] **Import File…** with a wrong file (for example an `.m4a`) is refused: "The file is not the expected model
      (its size or checksum differs), so it was not used." Importing a copy of the right file installs it.
- [ ] In the welcome guide (Settings › General › **Show Welcome Guide Again**, step 4) with the model deleted,
      **Download** shows a percentage and a cancel button, then "Ready".

**After each save (Parakeet)**

- [ ] With "After each save", save a 2-minute two-sided call: a "Transcript ready" notification shows the word
      count, and the Library shows lines labelled You and System at the right times. The sidecar's transcript has
      `"locale" : "en"`.
- [ ] In Activity Monitor, Tapeloop's memory rises by about 0.8 GB while the transcript is made and falls back
      afterwards. The log shows "Parakeet model loaded in … s" and then "Parakeet model unloaded".
- [ ] With "One file per source", each file gets its own transcript with its own label.

**Live while recording**

- [ ] Choose "Live while recording". The log shows "Live transcription on". In Activity Monitor, Tapeloop's memory
      is about 0.8 GB higher and stays there while recording.
- [ ] Talk and play a video for 2 minutes, then save the last minute. The transcript is in the Library within a
      few seconds of the save (log: "Live transcript written: N lines"), with no long "Transcribing…" spinner.
- [ ] Turn live mode on, wait one minute, and save the last 5 minutes (a span that starts before live mode): the
      save falls back to transcribing after the save, and the transcript still covers the whole span.
- [ ] Sit in silence for a minute with nothing playing: Activity Monitor's GPU column for Tapeloop stays near zero
      (silent pieces are not transcribed).
- [ ] Choose "After each save" again: the log shows "Live transcription off" and the memory drops by about
      0.8 GB.

**Only when I ask, engines and deleting**

- [ ] With "Only when I ask", a save makes no transcript; the Library shows **Transcribe**, which works and shows
      "Transcribing…" meanwhile.
- [ ] Switch the engine to "Apple speech recognition": the Speech model row is replaced by Permission and Language,
      and "When" offers only "After each save" and "Only when I ask". Allow Speech Recognition when asked. A save
      is transcribed by Apple's recognizer (the sidecar's `locale` is the chosen language, for example `en-US`).
- [ ] A language without an on-device model is not offered in the language list.
- [ ] Switch back to Parakeet: the next save is transcribed with Parakeet again.
- [ ] **Delete…** asks "Delete the speech model?"; **Delete** removes the file from the Models folder, the row
      shows **Download** again, and existing transcripts stay in the Library. With Parakeet still chosen, a save
      makes no transcript (log: "Not transcribing: The Parakeet speech model is not downloaded…"), and
      **Transcribe** in the Library opens Settings › Transcripts.

### 3.9 Library

- [ ] Recordings are grouped as Today, Yesterday and dated days, newest first.
- [ ] Search finds a word from a transcript, a bookmark label, a meeting app and a calendar title; matches are
      highlighted in the transcript.
- [ ] Play, pause (Space), seek on the waveform, the next-bookmark button and each speed (1×, 1.25×, 1.5×, 2×) work.
      Clicking a transcript time plays from there.
- [ ] **Rename** (pencil or Return): the title changes, the file is renamed to `Tapeloop <date> (<length>)
      <title>.m4a`, and the sidecar in `.tapeloop/` moves with it.
- [ ] **Delete**: after the confirmation the file is in the Trash and its sidecar is gone.
- [ ] **Share** opens the system share sheet; **Show in Finder** reveals the file.
- [ ] **Export Transcript** › Plain Text and › Subtitles write `.txt` and `.srt` files that open correctly.
- [ ] Adding or removing a file in Finder updates the open Library within a second.
- [ ] Changing the save folder in Settings › General switches the Library to the new folder.

### 3.10 Windows, quit, login and appearance

- [ ] With Settings or the Library open: Tapeloop is in the Dock and ⌘-Tab; ⌘, opens Settings, ⌘L the Library,
      ⌘W closes the front window, and ⌘C, ⌘V and ⌘A work in the Library's search field and the rename field.
- [ ] Closing the last Tapeloop window removes it from the Dock and ⌘-Tab; the menu bar cassette stays.
- [ ] A permission prompt from Settings (Calendar, Speech Recognition) leaves the Settings window in front when it
      closes.

- [ ] Quit with more than 1 minute held: the alert offers **Save Last N and Quit**, **Quit** and **Cancel**.
      **Save Last N and Quit** saves, then quits. **Cancel** keeps recording. "Do not ask again" turns the warning
      off in Settings › General.
- [ ] After quitting, the spill folder is gone and relaunching starts with an empty buffer.
- [ ] **Launch at login:** with "Open Tapeloop when I log in" on, log out and in: Tapeloop starts recording
      without the guide. The item appears in System Settings › General › Login Items.
- [ ] **Light and dark:** switch System Settings › Appearance. The menu bar icon, popover, Settings, guide and
      Library are readable in both.
- [ ] **VoiceOver:** with VoiceOver on, the timeline reads "Rewind timeline, Saving the last N min"; VO-Up and
      VO-Down (adjust) move the selection by one minute; every popover button has a name.

### 3.11 Update path

- [ ] Install the new DMG over the previous version. Note whether macOS asks for the permissions again (expected
      for ad-hoc signed builds) and that settings, recordings and the downloaded speech model are kept.
