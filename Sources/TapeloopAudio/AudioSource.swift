#if os(macOS)
    @preconcurrency import AVFoundation
    import Foundation
    import TapeloopCore

    /// Called for each captured PCM buffer with the wall-clock time of its first sample. Runs on an audio thread;
    /// the buffer is valid only during the call.
    public typealias AudioBufferHandler = @Sendable (AVAudioPCMBuffer, Date) -> Void

    /// Something that captures live audio: the microphone, the system audio, and later other inputs (a single app,
    /// an external interface). The recorder engine treats every source the same way.
    public protocol AudioSource: AnyObject, Sendable {
        /// Which buffer the audio goes to.
        var kind: SourceKind { get }
        /// Starts capture. `onEvent` reports restarts and failures in plain words, for logs and the UI.
        func start(onBuffer: @escaping AudioBufferHandler, onEvent: @escaping @Sendable (SourceEvent) -> Void) throws
        /// Stops capture. Safe to call when not running.
        func stop()
    }

    /// Something that happened to a running source.
    public enum SourceEvent: Sendable, Equatable {
        /// The source restarted, for example after a device change. Expect a gap.
        case restarted(String)
        /// The source stopped and could not restart.
        case failed(String)
    }
#endif
