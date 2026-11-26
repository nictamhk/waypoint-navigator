import Foundation

/// One MapKit route between two consecutive waypoints (metadata only;
/// the vertices live in the merged `RouteGeometry`).
public struct RouteLeg: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID { toWaypointID }
    public let fromWaypointID: UUID
    public let toWaypointID: UUID
    /// Distance as reported by MapKit.
    public let distance: Double
    public let expectedTravelTime: TimeInterval
    public let fetchedAt: Date

    public init(fromWaypointID: UUID, toWaypointID: UUID, distance: Double,
                expectedTravelTime: TimeInterval, fetchedAt: Date) {
        self.fromWaypointID = fromWaypointID
        self.toWaypointID = toWaypointID
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.fetchedAt = fetchedAt
    }
}

/// Where a waypoint sits on the merged route, and when the plan says we reach it.
public struct StopPlan: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID { waypointID }
    public let waypointID: UUID
    public let index: Int
    /// Distance along the merged route, meters.
    public let chainage: Double
    /// Seconds after the planned departure (baseline schedule).
    public let baselineOffset: TimeInterval
    public let baselineArrival: Date

    public init(waypointID: UUID, index: Int, chainage: Double,
                baselineOffset: TimeInterval, baselineArrival: Date) {
        self.waypointID = waypointID
        self.index = index
        self.chainage = chainage
        self.baselineOffset = baselineOffset
        self.baselineArrival = baselineArrival
    }
}

public enum RouteWarning: Codable, Sendable, Equatable {
    /// MapKit's reported leg distance disagrees with the polyline length.
    case legDistanceMismatch(legIndex: Int, mapKitMeters: Double, geometryMeters: Double)
}

/// The "plan made at departure": waypoints, per-leg MapKit data, merged geometry
/// and the baseline schedule. Persisted so a relaunch needs no network.
public struct RouteSnapshot: Codable, Sendable, Equatable {
    public let id: UUID
    public let plannedDeparture: Date
    public let waypoints: [Waypoint]
    public let legs: [RouteLeg]
    public let geometry: RouteGeometry
    public let stops: [StopPlan]
    public let warnings: [RouteWarning]

    public init(id: UUID = UUID(), plannedDeparture: Date, waypoints: [Waypoint], legs: [RouteLeg],
                geometry: RouteGeometry, stops: [StopPlan], warnings: [RouteWarning]) {
        self.id = id
        self.plannedDeparture = plannedDeparture
        self.waypoints = waypoints
        self.legs = legs
        self.geometry = geometry
        self.stops = stops
        self.warnings = warnings
    }
}
