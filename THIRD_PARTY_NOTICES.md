# Third-party notices

Tapeloop's own code is MIT-licensed (see `LICENSE`). It includes or uses the following third-party work.

## transcribe.cpp (MIT)

The on-device speech recognition engine, version 0.4.2, by the transcribe.cpp authors. Its prebuilt macOS library and
its Swift wrapper are vendored in `ThirdParty/TranscribeCpp` with their licence texts. The library also contains, each
under the MIT licence: ggml (the ggml authors), miniz (Rich Geldreich, RAD Game Tools and Valve Software) and the
Silero VAD model (Silero Team). Their licence texts are in `ThirdParty/TranscribeCpp/CTranscribe.xcframework`.

## NVIDIA Parakeet Unified English 0.6B (CC-BY-4.0)

The optional speech model Tapeloop downloads on request: Parakeet Unified English 0.6B by NVIDIA, licensed under
Creative Commons Attribution 4.0 (<https://creativecommons.org/licenses/by/4.0/>). Tapeloop uses an 8-bit (Q8_0) GGUF
conversion for transcribe.cpp, hosted as an asset of Tapeloop's `models-v1` GitHub release (file
`parakeet-unified-en-0.6b-Q8_0.gguf`, SHA-256 4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795). The
conversion changes the numeric precision of the weights (quantization); nothing else is modified.
