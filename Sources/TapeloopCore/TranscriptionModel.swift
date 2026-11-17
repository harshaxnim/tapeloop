import Foundation

/// A speech model Tapeloop can download and run on this Mac.
public struct TranscriptionModel: Equatable, Sendable {
    /// A stable identifier.
    public var id: String
    /// The name shown to the user.
    public var name: String
    /// The file name on disk (and of the release asset).
    public var fileName: String
    /// The exact size in bytes.
    public var size: Int64
    /// The SHA-256 of the file, lowercase hex. Downloads and imports must match it.
    public var sha256: String
    /// Where the file is downloaded from: a release asset of Tapeloop's own GitHub repository.
    public var url: URL
    /// The language codes it recognizes.
    public var languages: [String]
    /// The licence of the model weights.
    public var licence: String

    /// Creates a catalog entry.
    public init(
        id: String, name: String, fileName: String, size: Int64, sha256: String, url: URL, languages: [String],
        licence: String
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.size = size
        self.sha256 = sha256
        self.url = url
        self.languages = languages
        self.licence = licence
    }

    /// The size for display, for example "731 MB".
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    /// NVIDIA Parakeet Unified English 0.6B, 8-bit quantized (Q8_0) GGUF for transcribe.cpp, hosted as an asset of
    /// Tapeloop's own `models-v1` GitHub release (see THIRD_PARTY_NOTICES.md and scripts/publish-model.sh).
    public static let parakeetUnifiedEnglish = TranscriptionModel(
        id: "parakeet-unified-en-0.6b-q8",
        name: "Parakeet Unified English 0.6B (8-bit)",
        fileName: "parakeet-unified-en-0.6b-Q8_0.gguf",
        size: 731_357_568,
        sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
        url: URL(
            string:
                "https://github.com/harshaxnim/tapeloop/releases/download/models-v1/parakeet-unified-en-0.6b-Q8_0.gguf"
        )!,
        languages: ["en"],
        licence: "CC-BY-4.0 (NVIDIA)")

    /// The model Tapeloop uses for Parakeet transcription.
    public static let `default` = parakeetUnifiedEnglish
}
