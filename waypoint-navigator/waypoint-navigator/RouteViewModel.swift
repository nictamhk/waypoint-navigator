import MapKit
import Observation

/// Holds the waypoints and the driving legs between them.
/// Asks Apple Maps for one leg at a time, and remembers legs it has already fetched.
@MainActor
@Observable
final class RouteViewModel {

    private(set) var waypoints: [MapWaypoint] = []
    private(set) var errorMessage: String?

    /// Legs already fetched, so adding one waypoint only requests one new leg.
    private var legCache: [LegKey: DrivingLeg] = [:]

    // MARK: - Derived values

    var waypointIDs: [UUID] { waypoints.map(\.id) }

    /// Legs for the current waypoints, in order (only those already calculated).
    var legs: [DrivingLeg] {
        zip(waypoints, waypoints.dropFirst()).compactMap { pair in
            legCache[LegKey(from: pair.0.id, to: pair.1.id)]
        }
    }

    var hasCompleteRoute: Bool {
        waypoints.count >= 2 && legs.count == waypoints.count - 1
    }

    var isCalculating: Bool {
        errorMessage == nil && waypoints.count >= 2 && legs.count < waypoints.count - 1
    }

    var totalDistance: CLLocationDistance { legs.reduce(0) { $0 + $1.distance } }
    var totalTravelTime: TimeInterval { legs.reduce(0) { $0 + $1.travelTime } }

    func markerKind(for waypoint: MapWaypoint) -> MarkerKind {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else {
            return .stop(0)
        }
        if index == 0 { return .start }
        if index == waypoints.count - 1 { return .end }
        return .stop(index)
    }

    // MARK: - Editing waypoints

    func addWaypoint(at coordinate: CLLocationCoordinate2D) {
        waypoints.append(MapWaypoint(coordinate: coordinate))
        errorMessage = nil
    }

    func removeWaypoint(_ waypoint: MapWaypoint) {
        waypoints.removeAll { $0.id == waypoint.id }
        legCache = legCache.filter { $0.key.from != waypoint.id && $0.key.to != waypoint.id }
        errorMessage = nil
    }

    func removeAll() {
        waypoints.removeAll()
        legCache.removeAll()
        errorMessage = nil
    }

    // MARK: - Route calculation

    /// Fetches every missing leg, one request at a time (Apple Maps throttles bursts).
    /// Safe to call again: finished legs are cached, and a cancelled call just stops.
    func updateRoute() async {
        errorMessage = nil

        let missingPairs = zip(waypoints, waypoints.dropFirst()).filter { pair in
            legCache[LegKey(from: pair.0.id, to: pair.1.id)] == nil
        }

        for pair in missingPairs {
            do {
                let leg = try await fetchLeg(from: pair.0, to: pair.1)
                legCache[leg.key] = leg          // keep it even if we were cancelled meanwhile
            } catch {
                if Task.isCancelled { return }
                errorMessage = message(for: error)
                return
            }
            if Task.isCancelled { return }
        }
    }

    private func fetchLeg(from start: MapWaypoint, to end: MapWaypoint) async throws -> DrivingLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw RouteError.noRouteFound
        }
        return DrivingLeg(
            key: LegKey(from: start.id, to: end.id),
            polyline: route.polyline,
            distance: route.distance,
            travelTime: route.expectedTravelTime
        )
    }

    private func message(for error: Error) -> String {
        if error is RouteError {
            return "No driving route found for one leg. Try moving a waypoint closer to a road."
        }
        if let mapError = error as? MKError {
            switch mapError.code {
            case .loadingThrottled:
                return "Apple Maps is busy. Wait a few seconds, then tap Retry."
            case .directionsNotFound:
                return "No driving route found for one leg. Try moving a waypoint closer to a road."
            default:
                break
            }
        }
        return "Could not calculate the route: \(error.localizedDescription)"
    }
}

private enum RouteError: Error {
    case noRouteFound
}
