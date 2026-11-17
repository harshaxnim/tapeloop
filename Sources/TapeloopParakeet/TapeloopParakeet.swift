#if os(macOS)
    import TranscribeCpp

    /// On-device transcription with NVIDIA Parakeet through transcribe.cpp: the model catalog and download, an
    /// after-save `Transcriber`, and a live transcriber that runs while recording.
    public enum TapeloopParakeetModule {
        /// The transcribe.cpp version this build links.
        public static var engineVersion: String { Transcribe.version() }
    }
#endif
