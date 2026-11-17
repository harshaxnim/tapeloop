#if os(macOS)
    import Darwin
    import Foundation

    /// Converts Core Audio host times (mach absolute time) into wall-clock dates, so every captured buffer carries
    /// the moment it was heard rather than the moment it reached our code.
    public enum HostClock {
        private static let timebase: mach_timebase_info_data_t = {
            var info = mach_timebase_info_data_t()
            mach_timebase_info(&info)
            return info
        }()

        /// The wall-clock date of `hostTime`, or `Date()` when `hostTime` is 0 (not valid).
        public static func date(forHostTime hostTime: UInt64) -> Date {
            guard hostTime > 0 else { return Date() }
            let now = mach_absolute_time()
            let delta = Int64(bitPattern: now &- hostTime)
            let seconds = Double(delta) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            return Date().addingTimeInterval(-seconds)
        }
    }
#endif
