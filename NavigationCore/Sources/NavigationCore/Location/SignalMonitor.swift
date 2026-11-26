import Foundation

public enum SignalState: String, Sendable, Equatable {
    /// No acceptable fix yet.
    case acquiring
    case good
    /// Poor accuracy, or a short gap since the last acceptable fix.
    case degraded
    /// Long gap since the last acceptable fix.
    case lost
}

/// Tracks GPS signal health from the stream of verdicts plus a watchdog tick.
/// Core Location simply stops delivering when the signal is lost, so something must call `tick`.
public struct SignalMonitor: Sendable {
    public struct Configuration: Sendable {
        public var degradedAfter: TimeInterval = 5
        public var lostAfter: TimeInterval = 15
        public init() {}
    }

    public private(set) var state: SignalState = .acquiring
    private let configuration: Configuration
    private var lastAcceptedAt: Date?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func record(_ verdict: LocationQualityFilter.Verdict, at time: Date) -> SignalState {
        switch verdict {
        case .good:
            lastAcceptedAt = time
            state = .good
        case .degraded:
            lastAcceptedAt = time
            state = .degraded
        case .rejected:
            return tick(at: time)
        }
        return state
    }

    /// Call periodically (about once per second live; with the current simulated time in replays).
    @discardableResult
    public mutating func tick(at time: Date) -> SignalState {
        guard let last = lastAcceptedAt else { return state }
        let gap = time.timeIntervalSince(last)
        if gap >= configuration.lostAfter {
            state = .lost
        } else if gap >= configuration.degradedAfter && state == .good {
            state = .degraded
        }
        return state
    }
}
