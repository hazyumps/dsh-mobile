import Foundation

/// A caller-supplied time source, in the same unit the wire uses: epoch
/// milliseconds. Pairing expiry is compared against this rather than against
/// `Date()` internally so validation stays testable and the app can pass a clock
/// that is safe to inject across actors (SPEC §3.2 step 1).
public protocol EpochClock: Sendable {
    /// Current time in milliseconds since the Unix epoch.
    func epochMillis() -> Int64
}

/// The real wall clock.
public struct SystemEpochClock: EpochClock {
    public init() {}

    public func epochMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

/// A frozen clock, for tests and for replaying a captured pairing payload.
public struct FixedEpochClock: EpochClock {
    public let millis: Int64

    public init(millis: Int64) {
        self.millis = millis
    }

    public init(date: Date) {
        self.millis = Int64(date.timeIntervalSince1970 * 1000)
    }

    public func epochMillis() -> Int64 { millis }
}
