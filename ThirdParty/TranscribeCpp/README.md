# TranscribeCpp (vendored)

The speech-recognition engine transcribe.cpp (MIT licence, version **0.4.2**), kept inside this repository so Tapeloop
builds without fetching anything from other projects:

- `CTranscribe.xcframework`: the engine's prebuilt macOS library (universal arm64 + x86_64, Metal), taken unchanged
  from the 0.4.2 release with only the iOS slices removed. Its licence files (transcribe.cpp, ggml, miniz, Silero VAD)
  are inside it.
- `Sources/`: the engine's Swift wrapper, copied unchanged from the same version. See `LICENSE`.

To update: replace both from the new version (keep only the `macos-arm64_x86_64` library in the xcframework and its
`Info.plist` entry), build, and run `swift test --filter TapeloopParakeetTests` with the model installed.
