# Tapeloop

> **Work in progress.** Tapeloop is being built in the open. The first release (v0.1.0) is not out yet.

Tapeloop is a free, open-source macOS menu bar app that keeps a short, private, rolling recording of your
screen, your microphone and your Mac's sound. When something worth keeping has *already* happened (a good
idea in a call, a bug on screen, the last ten minutes of a lecture), you rewind and save it.

- **Always local.** Recordings never leave your Mac. Tapeloop makes no network calls.
- **Rolling buffer.** You choose how much to keep (15 minutes to 5 hours) and a disk limit; older material is deleted.
- **Rewind and save.** Drag back on the timeline in the menu bar, or press a hotkey to save the last N minutes.
- **Bookmarks, meetings, calendar, transcripts** (on-device). See [the plan](docs/PLAN.md).

Requires macOS 14 (Sonoma) or later, on Apple silicon or Intel.

## Install

Download `Tapeloop-<version>.dmg` from [Releases](https://github.com/harshaxnim/tapeloop/releases), open it and
drag Tapeloop to Applications. Builds are not notarized yet, so macOS blocks the first launch. Either
right-click Tapeloop in Applications and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Tapeloop.app
```

## Build from source

```sh
make build      # debug build
make test       # unit tests
make app        # build/Tapeloop.app (universal, ad-hoc signed)
make dmg        # build/Tapeloop-<version>.dmg
make snapshots  # render the UI to PNG in build/snapshots
```

You need Xcode 16 or the Swift 6 toolchain. The core logic (`TapeloopCore`) also builds and tests on Linux.
See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Privacy

Tapeloop records only on your Mac, into `~/Library/Application Support/Tapeloop/Buffer`. It shows when it is
recording, pauses with one click, and can pause when the screen locks. Saved recordings go to the folder you
choose. There is no telemetry and no account.

## License

MIT. See [LICENSE](LICENSE).
