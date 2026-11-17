# Tapeloop

> **Work in progress.** Tapeloop is being built in the open. The first release (v0.1.0) is not out yet.

Tapeloop is a free, open-source macOS menu bar app that is an endless tape loop for your audio. It always keeps
the last minutes (up to hours) of your **microphone** and your **Mac's sound** (for example the other side of a
call), compressed, **in memory only**. When something worth keeping has *already* happened (a promise in a call,
a lecturer's aside, an idea you said out loud), you rewind and save it.

- **In memory, compressed.** Audio is encoded to AAC as it arrives and kept in RAM: two sources at 48 kbps cost
  about 78 MB per hour, about 216 MB for 5 hours. Nothing is written to disk until you save. Quit, and it is gone.
- **Disk only if you allow it.** Past 500 MB (a setting), Tapeloop either shortens the buffer or, if you allow it,
  keeps the oldest part in a cache folder that is wiped on quit and on launch.
- **Rewind and save.** Pull the tape back on the timeline in the menu bar, or save the last 5/15/30/60 minutes.
- **Bookmarks, meetings, calendar, transcripts** (all on device). See [the plan](docs/PLAN.md).
- **No network.** Tapeloop makes no network calls, has no account and no telemetry.

Requires macOS 14 (Sonoma) or later; system audio capture needs macOS 14.2 or later. Apple silicon or Intel.

## Install

Download `Tapeloop-<version>.dmg` from [Releases](https://github.com/harshaxnim/tapeloop/releases), open it and
drag Tapeloop to Applications. Builds are ad-hoc signed and not notarized, so macOS blocks the first launch.
Either right-click Tapeloop in Applications and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Tapeloop.app
```

Because ad-hoc signatures change with every build, macOS may ask for the microphone and system audio
permissions again after an update.

## Permissions

- **Microphone**: to keep your side of a conversation.
- **System Audio Recording**: to keep what your Mac plays (the other side of a call). Tapeloop uses a Core Audio
  process tap, which does not need the Screen Recording permission.

## Build from source

```sh
make build      # debug build
make test       # unit tests
make app        # build/Tapeloop.app (this Mac's architecture, ad-hoc signed)
make run        # build and open the app
make probe      # record 10 s of mic + system audio into RAM, write build/probe/*.m4a, print a report
make dmg        # build/Tapeloop-<version>.dmg (universal)
make snapshots  # render the UI to PNG in build/snapshots
```

You need Xcode 16.2 (Swift 6.0) or later. The core logic (`TapeloopCore`) also builds and tests on Linux.
See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

MIT. See [LICENSE](LICENSE).
