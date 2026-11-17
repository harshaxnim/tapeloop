# Changelog

## Unreleased
- Renamed the project to Tapeloop (formerly a scaffold called Rearview) and narrowed it to audio only.
- In-RAM compressed buffer core: `EncodedChunk`, `ChunkRing`, `MemoryBudget` (the 500 MB plan), `RecordingName`.
- Audio: AAC-LC encoder, microphone source, system audio through a Core Audio process tap (macOS 14.2+).
- Export: passthrough `.m4a` writer (no re-encode).
- `make probe`: records 10 s of mic and system audio into RAM and writes them to `.m4a`.
- Menu bar shell with an original cassette icon (recording, paused, needs-attention states).
- CI on Xcode 16.2: format, lint, build, tests, UI snapshots, universal app, verified DMG.
