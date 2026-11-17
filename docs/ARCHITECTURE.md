# Architecture

The module map, data layout and extension points are in [PLAN.md, section 2](PLAN.md#2-hat-2-architecture).
This file grows into the full guide as the modules are built.

| Module | Role | Platforms |
|---|---|---|
| `TapeloopCore` | Models and logic: time ranges, segment index, retention, save planning, naming, settings | macOS, Linux |
| `TapeloopCapture` | Screen, microphone and system audio capture; segment writer | macOS |
| `TapeloopExport` | Stitches segments into one file | macOS |
| `TapeloopIntelligence` | Transcription, meeting detection, calendar, login item | macOS |
| `TapeloopUI` | SwiftUI views and view models | macOS |
| `Tapeloop` | The app: status item, windows, hotkeys, wiring | macOS |
| `TapeloopSnapshots` | Renders the UI to PNG for CI | macOS |
