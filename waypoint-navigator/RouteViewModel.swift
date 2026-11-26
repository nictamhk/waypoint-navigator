import MapKit
import Observation

/// Holds the waypoints and the driving legs between them.
/// Asks Apple Maps for one leg at a time, and remembers legs it has already fetched.
@MainActor
@Observable
final class RouteViewModel {

    private(set) var waypoints: [MapWaypoint] = []
    private(set) var errorMessage: String?
    private(set) var saveMessage: String?

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

    /// Estimated drive time for the leg ending at the waypoint at `index`.
    func estimatedLegTime(at index: Int) -> TimeInterval? {
        guard waypoints.indices.contains(index) else { return nil }
        guard index > 0 else { return 0 }
        let key = LegKey(from: waypoints[index - 1].id, to: waypoints[index].id)
        return legCache[key]?.travelTime
    }

    /// Tentative arrival based on the currently calculated legs and a departure time of `now`.
    /// Returns nil until every leg from the start through this waypoint is available.
    func estimatedArrival(at index: Int, departingAt departure: Date = .now) -> Date? {
        guard waypoints.indices.contains(index) else { return nil }
        var elapsed: TimeInterval = 0
        if index > 0 {
            for legIndex in 1...index {
                guard let legTime = estimatedLegTime(at: legIndex) else { return nil }
                elapsed += legTime
            }
        }
        return departure.addingTimeInterval(elapsed)
    }

    func markerKind(for waypoint: MapWaypoint) -> MarkerKind {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else {
            return .stop(0)
        }
        if index == 0 { return .start }
        if index == waypoints.count - 1 { return .end }
        return .stop(index)
    }

    /// Places a waypoint marker on its nearest calculated adjacent route segment.
    /// The tapped coordinate remains the routing/editing input; this is a display snap only.
    /// MapKit doesn't expose a general-purpose road-snapping API, so leave markers untouched
    /// when the route geometry is too far away to be a credible match.
    func displayedCoordinate(for waypoint: MapWaypoint) -> CLLocationCoordinate2D {
        let adjacentLegs = legs.filter {
            $0.key.from == waypoint.id || $0.key.to == waypoint.id
        }
        var nearest: (coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)?

        for leg in adjacentLegs {
            let count = leg.polyline.pointCount
            guard count >= 2 else { continue }
            let points = leg.polyline.points()
            let tap = MKMapPoint(waypoint.coordinate)

            for index in 0..<(count - 1) {
                let start = points[index]
                let end = points[index + 1]
                let dx = end.x - start.x
                let dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                guard lengthSquared > 0 else { continue }

                let fraction = min(1, max(0,
                    ((tap.x - start.x) * dx + (tap.y - start.y) * dy) / lengthSquared
                ))
                let projected = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
                let coordinate = projected.coordinate
                let distance = CLLocation(latitude: waypoint.coordinate.latitude,
                                          longitude: waypoint.coordinate.longitude)
                    .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))

                if nearest == nil || distance < nearest!.distance {
                    nearest = (coordinate, distance)
                }
            }
        }

        guard let nearest, nearest.distance <= 60 else { return waypoint.coordinate }
        return nearest.coordinate
    }

    // MARK: - Editing waypoints

    func addWaypoint(at coordinate: CLLocationCoordinate2D) {
        waypoints.append(MapWaypoint(coordinate: coordinate))
        errorMessage = nil
        saveMessage = nil
    }

    func moveWaypoints(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty else { return }
        var reordered = waypoints
        let moving = source.map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: min(max(adjustedDestination, 0), reordered.count))
        waypoints = reordered
        errorMessage = nil
        saveMessage = nil
    }

    func removeWaypoints(at offsets: IndexSet) {
        let removedIDs = Set(offsets.compactMap { waypoints.indices.contains($0) ? waypoints[$0].id : nil })
        for offset in offsets.sorted(by: >) where waypoints.indices.contains(offset) {
            waypoints.remove(at: offset)
        }
        legCache = legCache.filter { !removedIDs.contains($0.key.from) && !removedIDs.contains($0.key.to) }
        errorMessage = nil
        saveMessage = nil
    }

    func saveRoute(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, hasCompleteRoute else { return }
        do {
            try SavedRouteStore.append(SavedRoute(name: trimmedName, waypoints: waypoints))
            saveMessage = "Saved “\(trimmedName)” on this iPhone."
        } catch {
            saveMessage = "Could not save route: \(error.localizedDescription)"
        }
    }

    func removeWaypoint(_ waypoint: MapWaypoint) {
        waypoints.removeAll { $0.id == waypoint.id }
        legCache = legCache.filter { $0.key.from != waypoint.id && $0.key.to != waypoint.id }
        errorMessage = nil
        saveMessage = nil
    }

    func removeAll() {
        waypoints.removeAll()
        legCache.removeAll()
        errorMessage = nil
        saveMessage = nil
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
