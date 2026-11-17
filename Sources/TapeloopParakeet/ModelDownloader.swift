#if os(macOS)
    import CryptoKit
    import Foundation
    import TapeloopCore
    import os

    /// Keeps the downloaded speech model: where it lives, whether it is installed, and downloading, importing,
    /// verifying and deleting it.
    ///
    /// This file holds Tapeloop's only network code (CI enforces that). A download happens only when the user asks
    /// for one, fetches a single file from Tapeloop's own GitHub release, and is accepted only if its SHA-256 matches
    /// the catalog.
    public final class ModelStore: NSObject, @unchecked Sendable, URLSessionDownloadDelegate {
        /// The model's state.
        public enum State: Equatable, Sendable {
            case notInstalled
            /// Downloading; the fraction is 0 to 1.
            case downloading(Double)
            /// Checking the file's SHA-256.
            case verifying
            case installed
            /// The last download or import failed; the message is for the user.
            case failed(String)
        }

        /// The model this store manages.
        public let model: TranscriptionModel
        /// The folder that holds model files.
        public let folder: URL
        private let lock = NSLock()
        private var _state: State = .notInstalled
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private let log = Logger(subsystem: TapeloopInfo.bundleIdentifier, category: "models")
        /// Called (on any thread) whenever `state` changes.
        public var onChange: (@Sendable (State) -> Void)?

        /// `~/Library/Application Support/Tapeloop/Models`.
        public static var defaultFolder: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Tapeloop/Models", isDirectory: true)
        }

        /// Creates the store and reads whether the model is installed.
        public init(model: TranscriptionModel = .default, folder: URL = ModelStore.defaultFolder) {
            self.model = model
            self.folder = folder
            super.init()
            _state = isInstalled ? .installed : .notInstalled
        }

        /// The current state. When idle, it is re-read from disk, so a model file copied into the folder (or removed)
        /// while Tapeloop runs is noticed.
        public var state: State {
            let current = lock.withLock { _state }
            switch current {
            case .notInstalled, .installed:
                let onDisk: State = isInstalled ? .installed : .notInstalled
                if onDisk != current { set(onDisk) }
                return onDisk
            default:
                return current
            }
        }

        /// The model file's location (it may not exist).
        public var fileURL: URL { folder.appendingPathComponent(model.fileName) }

        /// Whether the file exists with the expected size (the hash is checked when it is installed).
        public var isInstalled: Bool {
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
            return size == model.size
        }

        private func set(_ state: State) {
            let changed = lock.withLock {
                guard _state != state else { return false }
                _state = state
                return true
            }
            if changed { onChange?(state) }
        }

        // MARK: - Download

        /// Starts downloading the model (does nothing when it is installed or already downloading).
        public func download() {
            let busy = lock.withLock { self.task != nil }
            guard !busy, !isInstalled else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 6 * 3600
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: model.url)
            lock.withLock {
                self.session = session
                self.task = task
            }
            log.info(
                "Downloading \(self.model.fileName, privacy: .public) from \(self.model.url.absoluteString, privacy: .public)"
            )
            set(.downloading(0))
            task.resume()
        }

        /// Cancels a download in progress.
        public func cancel() {
            let task = lock.withLock { () -> URLSessionDownloadTask? in
                let current = self.task
                self.task = nil
                return current
            }
            task?.cancel()
            session?.invalidateAndCancel()
            set(isInstalled ? .installed : .notInstalled)
        }

        public func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.size
            let fraction = min(1, Double(totalBytesWritten) / Double(max(1, total)))
            // Report in steps of 0.5 % so the UI is not flooded.
            if case .downloading(let last) = state, fraction - last < 0.005, fraction < 1 { return }
            set(.downloading(fraction))
        }

        public func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            // The temporary file is deleted when this method returns: move it first.
            let staged = folder.appendingPathComponent(".\(model.fileName).download")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: staged)
                if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
                    throw StoreError.http(response.statusCode)
                }
                try FileManager.default.moveItem(at: location, to: staged)
                install(staged, removeSource: true)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                fail(error)
            }
        }

        public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock { self.task = nil }
            session.finishTasksAndInvalidate()
            guard let error else { return }
            if (error as NSError).code == NSURLErrorCancelled { return }
            fail(error)
        }

        // MARK: - Import, verify, delete

        /// Installs a model file the user already has (for example, downloaded in a browser). It must be the exact
        /// file in the catalog.
        public func importFile(at url: URL) {
            let staged = folder.appendingPathComponent(".\(model.fileName).import")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: url, to: staged)
            } catch {
                fail(error)
                return
            }
            DispatchQueue.global(qos: .utility).async { self.install(staged, removeSource: true) }
        }

        /// Checks the staged file's size and hash, then moves it into place.
        private func install(_ staged: URL, removeSource: Bool) {
            set(.verifying)
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?
                    .int64Value
                guard size == model.size else { throw StoreError.mismatch }
                guard try Self.sha256(of: staged) == model.sha256 else { throw StoreError.mismatch }
                try? FileManager.default.removeItem(at: fileURL)
                try FileManager.default.moveItem(at: staged, to: fileURL)
                log.info("Installed \(self.model.fileName, privacy: .public)")
                set(.installed)
            } catch {
                if removeSource { try? FileManager.default.removeItem(at: staged) }
                fail(error)
            }
        }

        /// Deletes the installed model.
        public func delete() {
            try? FileManager.default.removeItem(at: fileURL)
            set(.notInstalled)
        }

        private func fail(_ error: Error) {
            log.error("Model install failed: \(String(describing: error), privacy: .public)")
            let message: String
            switch error {
            case StoreError.mismatch:
                message = "The file is not the expected model (its size or checksum differs), so it was not used."
            case StoreError.http(let code):
                message = "The download failed (the server answered with code \(code)). Try again later."
            default:
                if (error as NSError).domain == NSURLErrorDomain {
                    message = "The download failed: \(error.localizedDescription)"
                } else {
                    message = "The model could not be saved: \(error.localizedDescription)"
                }
            }
            set(.failed(message))
        }

        /// The SHA-256 of a file, lowercase hex, read in 4 MB pieces.
        public static func sha256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        enum StoreError: Error {
            case mismatch
            case http(Int)
        }
    }
#endif
