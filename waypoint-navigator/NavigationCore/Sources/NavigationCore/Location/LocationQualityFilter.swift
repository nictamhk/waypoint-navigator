import Foundation

/// Decides whether a fix is trustworthy enough to use. Pure and deterministic.
public struct LocationQualityFilter: Sendable {
    public struct Configuration: Sendable {
        /// Accuracy (m) at or below which a fix counts as good.
        public var goodAccuracy = 20.0
        /// Accuracy (m) above which a fix is rejected outright.
        public var maxAccuracy = 50.0
        /// Fixes older than this (seconds, relative to `now`) are stale.
        public var maxAge: TimeInterval = 10
        /// Implied speed (m/s) above which a position change is treated as a GPS jump.
        public var maxPlausibleSpeed = 70.0
        /// Displacements smaller than this are never treated as jumps.
        public var jumpMinDistance = 30.0
        /// After this many consecutive jump rejections the new position is accepted as the truth.
        public var rebaselineAfterJumps = 5
        public var rejectSimulated = false

        public init() {}
    }

    public enum Rejection: String, Sendable, Equatable {
        case invalidAccuracy, poorAccuracy, stale, outOfOrder, implausibleJump, simulated
    }

    public enum Verdict: Sendable, Equatable {
        case good
        case degraded
        case rejected(Rejection)
    }

    private let configuration: Configuration
    private var lastAccepted: LocationFix?
    private var consecutiveJumps = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        lastAccepted = nil
        consecutiveJumps = 0
    }

    /// - Parameter now: wall-clock time for the staleness check. Pass nil when replaying recorded tracks.
    public mutating func assess(_ fix: LocationFix, now: Date? = nil) -> Verdict {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy.isFinite else { return .rejected(.invalidAccuracy) }
        if configuration.rejectSimulated && fix.isSimulated { return .rejected(.simulated) }
        if let now, now.timeIntervalSince(fix.timestamp) > configuration.maxAge { return .rejected(.stale) }
        if fix.horizontalAccuracy > configuration.maxAccuracy { return .rejected(.poorAccuracy) }

        if let last = lastAccepted {
            let dt = fix.timestamp.timeIntervalSince(last.timestamp)
            if dt <= 0 { return .rejected(.outOfOrder) }
            let distance = last.coordinate.distance(to: fix.coordinate)
            let allowance = last.horizontalAccuracy + fix.horizontalAccuracy
            if distance > max(configuration.jumpMinDistance, allowance),
               distance / dt > configuration.maxPlausibleSpeed {
                consecutiveJumps += 1
                if consecutiveJumps < configuration.rebaselineAfterJumps {
                    return .rejected(.implausibleJump)
                }
                // Sustained offset: treat the new position as the truth.
            }
        }
        consecutiveJumps = 0
        lastAccepted = fix
        return fix.horizontalAccuracy <= configuration.goodAccuracy ? .good : .degraded
    }
}
