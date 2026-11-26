import Foundation

/// Combines quality filtering, signal monitoring and route matching into one deterministic unit.
/// The NavigationEngine feeds it fixes (and a watchdog tick) and reads the resulting observations.
public struct RouteMatchingService: Sendable {
    public struct Observation: Sendable {
        public let fix: LocationFix
        public let verdict: LocationQualityFilter.Verdict
        /// nil when the fix was rejected (or the route is degenerate).
        public let match: RouteMatch?
        public let signal: SignalState

        public init(fix: LocationFix, verdict: LocationQualityFilter.Verdict, match: RouteMatch?, signal: SignalState) {
            self.fix = fix
            self.verdict = verdict
            self.match = match
            self.signal = signal
        }

        /// True when announcements may be driven by this observation.
        public var isReliable: Bool {
            guard signal == .good, let match else { return false }
            return match.confidence != .low && !match.isReversing
        }
    }

    private var filter: LocationQualityFilter
    private var matcher: RouteMatcher
    private var monitor: SignalMonitor

    public init(geometry: RouteGeometry,
                filter: LocationQualityFilter.Configuration = LocationQualityFilter.Configuration(),
                matcher: RouteMatcher.Configuration = RouteMatcher.Configuration(),
                signal: SignalMonitor.Configuration = SignalMonitor.Configuration()) {
        self.filter = LocationQualityFilter(configuration: filter)
        self.matcher = RouteMatcher(geometry: geometry, configuration: matcher)
        self.monitor = SignalMonitor(configuration: signal)
    }

    public var geometry: RouteGeometry { matcher.geometry }
    public var signalState: SignalState { monitor.state }

    /// - Parameter now: wall-clock time for staleness and signal timing; nil in replays (fix time is used).
    public mutating func ingest(_ fix: LocationFix, now: Date? = nil) -> Observation {
        let verdict = filter.assess(fix, now: now)
        let signal = monitor.record(verdict, at: now ?? fix.timestamp)
        var match: RouteMatch?
        switch verdict {
        case .good, .degraded: match = matcher.update(fix)
        case .rejected: match = nil
        }
        return Observation(fix: fix, verdict: verdict, match: match, signal: signal)
    }

    /// Watchdog: call about once a second so signal loss is noticed even when no fixes arrive.
    @discardableResult
    public mutating func tick(now: Date) -> SignalState {
        monitor.tick(at: now)
    }

    /// Switches to new geometry (after a reroute). Progress restarts on the new route.
    public mutating func replaceGeometry(_ geometry: RouteGeometry) {
        matcher.reset(geometry: geometry)
        filter.reset()
    }
}
