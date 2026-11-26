import Foundation

public enum RouteError: Error, Equatable {
    case notEnoughWaypoints
    case coincidentWaypoints(index: Int)
    case legFailed(index: Int, reason: DirectionsError)
}

/// Owns route construction: one MapKit route per consecutive waypoint pair,
/// merged into a single chainage-indexed geometry plus a baseline schedule.
///
/// Not designed for concurrent builds; cancel the previous build before starting another.
public actor RouteManager {
    public struct Configuration: Sendable {
        public var maxRetries = 4
        public var baseBackoff: TimeInterval = 2
        /// Pause between consecutive network requests to stay clear of MapKit throttling.
        public var interRequestDelay: TimeInterval = 0.2
        /// Cached legs older than this are re-requested.
        public var maxLegCacheAge: TimeInterval = 3600
        /// Planned dwell at intermediate stops (0 for pass-through).
        public var dwellPerStop: TimeInterval = 0
        public var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
        public var now: @Sendable () -> Date = { Date() }

        public init() {}
    }

    private struct LegKey: Hashable {
        let fromLat: Int, fromLon: Int, toLat: Int, toLon: Int
        init(_ from: GeoCoordinate, _ to: GeoCoordinate) {
            // ~1 m resolution
            func q(_ v: Double) -> Int { Int((v * 1e5).rounded()) }
            fromLat = q(from.latitude); fromLon = q(from.longitude)
            toLat = q(to.latitude); toLon = q(to.longitude)
        }
    }

    private struct CachedLeg {
        let result: DirectionsResult
        let fetchedAt: Date
    }

    private let provider: any DirectionsProviding
    private let store: (any SnapshotStore)?
    private let configuration: Configuration
    private var cache: [LegKey: CachedLeg] = [:]
    private var needsPacing = false

    public init(provider: any DirectionsProviding,
                store: (any SnapshotStore)? = nil,
                configuration: Configuration = Configuration()) {
        self.provider = provider
        self.store = store
        self.configuration = configuration
    }

    public func loadPersistedSnapshot() -> RouteSnapshot? {
        guard let store else { return nil }
        return try? store.load()
    }

    /// Builds the route for an ordered waypoint list (N waypoints -> N-1 MapKit requests; unchanged
    /// legs come from the cache).
    public func buildSnapshot(
        waypoints: [Waypoint],
        plannedDeparture: Date,
        progress: (@Sendable (_ completedLegs: Int, _ totalLegs: Int) -> Void)? = nil
    ) async throws -> RouteSnapshot {
        guard waypoints.count >= 2 else { throw RouteError.notEnoughWaypoints }
        for i in 1..<waypoints.count {
            if waypoints[i - 1].coordinate.distance(to: waypoints[i].coordinate) < 1 {
                throw RouteError.coincidentWaypoints(index: i)
            }
        }

        needsPacing = false
        var results: [DirectionsResult] = []
        var legs: [RouteLeg] = []
        var elapsed: TimeInterval = 0

        for i in 1..<waypoints.count {
            try Task.checkCancellation()
            let (result, fetchedAt) = try await fetchLeg(
                from: waypoints[i - 1].coordinate,
                to: waypoints[i].coordinate,
                departure: plannedDeparture.addingTimeInterval(elapsed),
                index: i - 1
            )
            elapsed += result.expectedTravelTime + (i < waypoints.count - 1 ? configuration.dwellPerStop : 0)
            results.append(result)
            legs.append(RouteLeg(fromWaypointID: waypoints[i - 1].id, toWaypointID: waypoints[i].id,
                                 distance: result.distance, expectedTravelTime: result.expectedTravelTime,
                                 fetchedAt: fetchedAt))
            progress?(i, waypoints.count - 1)
        }

        let geometry = try RouteGeometry(legs: results.map(\.coordinates))
        let endChainages = geometry.legEndChainages

        // Baseline schedule = the plan made at departure.
        var stops: [StopPlan] = []
        var offset: TimeInterval = 0
        for (index, waypoint) in waypoints.enumerated() {
            if index > 0 { offset += legs[index - 1].expectedTravelTime }
            stops.append(StopPlan(
                waypointID: waypoint.id,
                index: index,
                chainage: index == 0 ? 0 : endChainages[index - 1],
                baselineOffset: offset,
                baselineArrival: plannedDeparture.addingTimeInterval(offset)
            ))
            if index > 0 && index < waypoints.count - 1 { offset += configuration.dwellPerStop }
        }

        // Flag legs whose MapKit distance disagrees with the polyline (e.g. routing quirks).
        var warnings: [RouteWarning] = []
        var previousEnd = 0.0
        for (i, end) in endChainages.enumerated() {
            let geometryLength = end - previousEnd
            previousEnd = end
            let reported = legs[i].distance
            if abs(geometryLength - reported) > max(25, 0.02 * reported) {
                warnings.append(.legDistanceMismatch(legIndex: i, mapKitMeters: reported, geometryMeters: geometryLength))
            }
        }

        let snapshot = RouteSnapshot(plannedDeparture: plannedDeparture, waypoints: waypoints, legs: legs,
                                     geometry: geometry, stops: stops, warnings: warnings)
        if let store { _ = try? store.save(snapshot) }
        return snapshot
    }

    private func fetchLeg(from: GeoCoordinate, to: GeoCoordinate, departure: Date,
                          index: Int) async throws -> (DirectionsResult, Date) {
        let key = LegKey(from, to)
        if let hit = cache[key], configuration.now().timeIntervalSince(hit.fetchedAt) <= configuration.maxLegCacheAge {
            return (hit.result, hit.fetchedAt)
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            if needsPacing { try await configuration.sleep(configuration.interRequestDelay) }
            do {
                let result = try await provider.route(from: from, to: to, departure: departure)
                needsPacing = true
                let fetchedAt = configuration.now()
                cache[key] = CachedLeg(result: result, fetchedAt: fetchedAt)
                return (result, fetchedAt)
            } catch let error as DirectionsError {
                guard error == .throttled, attempt < configuration.maxRetries else {
                    throw RouteError.legFailed(index: index, reason: error)
                }
                attempt += 1
                needsPacing = false
                try await configuration.sleep(configuration.baseBackoff * pow(2.0, Double(attempt - 1)))
            }
        }
    }
}
