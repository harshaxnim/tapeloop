# Architecture

The module map, data layout and extension points are in [PLAN.md, section 2](PLAN.md#2-hat-2-architecture).
This file grows into the full guide as the modules are built.

| Module | Role | Platforms |
|---|---|---|
| `RearviewCore` | Models and logic: time ranges, segment index, retention, save planning, naming, settings | macOS, Linux |
| `RearviewCapture` | Screen, microphone and system audio capture; segment writer | macOS |
| `RearviewExport` | Stitches segments into one file | macOS |
| `RearviewIntelligence` | Transcription, meeting detection, calendar, login item | macOS |
| `RearviewUI` | SwiftUI views and view models | macOS |
| `Rearview` | The app: status item, windows, hotkeys, wiring | macOS |
| `RearviewSnapshots` | Renders the UI to PNG for CI | macOS |
