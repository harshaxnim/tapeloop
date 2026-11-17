# Architecture

Tapeloop keeps a rolling buffer of microphone and system audio, compressed (AAC-LC), in RAM. The full design,
including the RAM model, the seams and the step plan, is in [PLAN.md](PLAN.md) section 2.

| Module | Role | Platforms |
|---|---|---|
| `TapeloopCore` | Pure models and logic: `EncodedChunk`, `ChunkRing` (the in-RAM ring), `MemoryBudget` (RAM arithmetic and the 500 MB plan), `TimeRange`, `RecordingName` | macOS, Linux |
| `TapeloopAudio` | Capture and encoding: `MicrophoneSource` (AVAudioEngine), `SystemAudioTap` (Core Audio process tap, macOS 14.2+), `AACEncoder`, `CaptureSink` | macOS |
| `TapeloopExport` | `M4AWriter`: writes AAC packets straight into `.m4a` (no re-encode) | macOS |
| `TapeloopIntelligence` | Transcription, meeting detection, calendar (step s4) | macOS |
| `TapeloopUI` | `CassetteIcon` (menu bar template icon), `RecorderStatus`, `PopoverView` | macOS |
| `Tapeloop` | The app: status item, popover, menu, `--probe` mode | macOS |
| `TapeloopSnapshots` | Renders the UI to PNG for CI | macOS |

Data path: source PCM → `CaptureSink` (lock) → `AACEncoder` (48 kHz mono, 48 kbps) → `EncodedChunk` (~5 s) →
`ChunkRing` → on save, `M4AWriter`. Raw PCM lives only for the length of one capture callback.

Logging: `os.Logger` with subsystem `io.github.harshaxnim.tapeloop`.
