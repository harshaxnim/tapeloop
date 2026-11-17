#if os(macOS)
    import AudioToolbox
    import Foundation
    import TapeloopCore

    /// One source's audio for a save: its chunks (oldest first) and the format to write or decode them.
    public struct ExportSource: @unchecked Sendable {
        /// The source.
        public var source: SourceKind
        /// The chunks, oldest first.
        public var chunks: [EncodedChunk]
        /// The AAC stream description.
        public var streamDescription: AudioStreamBasicDescription
        /// The AAC magic cookie.
        public var magicCookie: Data?

        /// Creates a source for export.
        public init(
            source: SourceKind, chunks: [EncodedChunk], streamDescription: AudioStreamBasicDescription,
            magicCookie: Data?
        ) {
            self.source = source
            self.chunks = chunks
            self.streamDescription = streamDescription
            self.magicCookie = magicCookie
        }
    }

    /// What to save.
    public struct ExportRequest: Sendable {
        /// The span to save; it is clamped to the audio that exists.
        public var range: TimeRange
        /// The sources to include.
        public var sources: [ExportSource]
        /// The folder to save into (created if missing).
        public var folder: URL
        /// An optional title for the file name (a meeting or event name).
        public var title: String?
        /// With two or more sources: one mixed file (`true`) or one file per source.
        public var mix: Bool
        /// The bit rate of a mixed file, in bits per second.
        public var mixBitRate: Int

        /// Creates a request.
        public init(
            range: TimeRange, sources: [ExportSource], folder: URL, title: String? = nil, mix: Bool = true,
            mixBitRate: Int = 64_000
        ) {
            self.range = range
            self.sources = sources
            self.folder = folder
            self.title = title
            self.mix = mix
            self.mixBitRate = mixBitRate
        }
    }

    /// What a save produced.
    public struct ExportResult: Sendable {
        /// The files written (one, or one per source).
        public var files: [URL]
        /// The span actually saved.
        public var range: TimeRange
        /// The sources in it.
        public var sources: [SourceKind]
    }

    /// Saves a span of the buffer to `.m4a` files.
    ///
    /// One source: the packets are copied as they are (passthrough, no quality loss, very fast). Several sources
    /// with `mix`: they are decoded, aligned by time (gaps become silence), summed and encoded once. Files are
    /// written under a hidden temporary name and renamed when complete, so a half-written file never appears.
    public enum Exporter {
        /// Errors from saving.
        public enum ExportError: Error, CustomStringConvertible {
            /// There is no audio in the requested span.
            case nothingToSave
            /// The folder could not be created or written.
            case folder(String)
            /// Writing failed.
            case write(String)
            /// The save was cancelled.
            case cancelled

            public var description: String {
                switch self {
                case .nothingToSave: "There is no recorded audio in that span."
                case .folder(let detail): "The save folder is not usable: \(detail)"
                case .write(let detail): "Saving failed: \(detail)"
                case .cancelled: "The save was cancelled."
                }
            }
        }

        /// Saves `request`. `progress` receives 0...1. Throws `cancelled` when the current task is cancelled.
        public static func save(
            _ request: ExportRequest, progress: @Sendable (Double) -> Void = { _ in }
        ) throws -> ExportResult {
            let sliced = request.sources.map { source in
                var copy = source
                copy.chunks = source.chunks.compactMap { $0.sliced(to: request.range) }
                return copy
            }.filter { !$0.chunks.isEmpty }
            guard let first = sliced.flatMap(\.chunks).map(\.start).min(),
                let last = sliced.flatMap(\.chunks).map(\.end).max()
            else { throw ExportError.nothingToSave }
            let saved = TimeRange(start: max(first, request.range.start), end: min(last, request.range.end))

            do {
                try FileManager.default.createDirectory(at: request.folder, withIntermediateDirectories: true)
            } catch {
                throw ExportError.folder(error.localizedDescription)
            }
            let baseName = RecordingName.make(start: saved.start, duration: saved.duration, title: request.title)

            var files: [URL] = []
            if sliced.count == 1 || !request.mix {
                for (index, source) in sliced.enumerated() {
                    let name =
                        sliced.count == 1
                        ? baseName
                        : baseName.replacingOccurrences(
                            of: ".m4a", with: " - \(source.source.label).m4a")
                    let url = try finalize(in: request.folder, name: name) { temp in
                        try M4AWriter.write(
                            source.chunks, format: source.streamDescription, magicCookie: source.magicCookie, to: temp)
                    }
                    files.append(url)
                    progress(Double(index + 1) / Double(sliced.count))
                }
            } else {
                let url = try finalize(in: request.folder, name: baseName) { temp in
                    try Mixer.mix(sliced, range: saved, bitRate: request.mixBitRate, to: temp, progress: progress)
                }
                files.append(url)
            }
            progress(1)
            return ExportResult(files: files, range: saved, sources: sliced.map(\.source))
        }

        /// Writes to a hidden temporary file in `folder`, then renames it to a free variant of `name`.
        private static func finalize(in folder: URL, name: String, write: (URL) throws -> Void) throws -> URL {
            let temp = folder.appendingPathComponent(".tapeloop-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                try write(temp)
            } catch let error as ExportError {
                throw error
            } catch {
                throw ExportError.write("\(error)")
            }
            let target = uniqueURL(in: folder, name: name)
            do {
                try FileManager.default.moveItem(at: temp, to: target)
            } catch {
                throw ExportError.write(error.localizedDescription)
            }
            return target
        }

        /// `name`, or `name 2`, `name 3`, … when a file with that name exists.
        static func uniqueURL(in folder: URL, name: String) -> URL {
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = folder.appendingPathComponent(name)
            var number = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(stem) \(number).\(ext)")
                number += 1
            }
            return candidate
        }
    }
#endif
