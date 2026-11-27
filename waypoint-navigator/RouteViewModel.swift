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
    private(set) var savedRoute: SavedRoute?
    private(set) var isRefreshingSavedRoute = false

    /// Legs already fetched, so adding one waypoint only requests one new leg.
    private var legCache: [LegKey: DrivingLeg] = [:]
    private var hasSetDefaultStart = false
    private var avoidHighwaysForCurrentRoute = false
    private var routingRevision = 0
    private var cacheGeneration = 0

    // MARK: - Derived values

    var waypointIDs: [UUID] { waypoints.map(\.id) }
    var routeTaskID: String {
        "\(routingRevision):\(waypointIDs.map(\.uuidString).joined(separator: ","))"
    }

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

    /// Seeds the route with the first live location, even if the user began adding stops
    /// before GPS permission or its first fix completed. This happens at most once per draft.
    func setDefaultStart(at coordinate: CLLocationCoordinate2D) {
        guard !hasSetDefaultStart else { return }
        hasSetDefaultStart = true
        waypoints.insert(MapWaypoint(coordinate: coordinate, title: "Current Location"), at: 0)
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
    }

    func addWaypoint(at coordinate: CLLocationCoordinate2D, title: String? = nil) {
        waypoints.append(MapWaypoint(coordinate: coordinate, title: title))
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
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
        savedRoute = nil
        isRefreshingSavedRoute = false
    }

    func removeWaypoints(at offsets: IndexSet) {
        let removedIDs = Set(offsets.compactMap { waypoints.indices.contains($0) ? waypoints[$0].id : nil })
        for offset in offsets.sorted(by: >) where waypoints.indices.contains(offset) {
            waypoints.remove(at: offset)
        }
        legCache = legCache.filter { !removedIDs.contains($0.key.from) && !removedIDs.contains($0.key.to) }
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
    }

    /// Rebuilds the route shape from an origin and destination, then places stops at regular
    /// distance intervals along the returned drivable geometry.
    func generateAutomaticRoute(from origin: CLLocationCoordinate2D,
                                to destination: CLLocationCoordinate2D,
                                destinationTitle: String?,
                                stopInterval: CLLocationDistance,
                                expressMode: Bool) async -> CLLocationDistance? {
        guard stopInterval > 0 else {
            errorMessage = "Choose a stop interval greater than zero."
            return nil
        }

        errorMessage = nil
        saveMessage = "Finding a driving route and generating stops…"
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.highwayPreference = expressMode ? .any : .avoid
        request.requestsAlternateRoutes = false

        do {
            let response = try await MKDirections(request: request).calculate()
            guard !Task.isCancelled else { return nil }
            guard let route = response.routes.first else {
                throw RouteError.noRouteFound
            }
            let coordinates = Self.coordinates(in: route.polyline)
            let segmentLengths = zip(coordinates, coordinates.dropFirst()).map { first, second in
                CLLocation(latitude: first.latitude, longitude: first.longitude)
                    .distance(from: CLLocation(latitude: second.latitude, longitude: second.longitude))
            }
            let routeLength = segmentLengths.reduce(0, +)
            guard routeLength > 0, coordinates.count >= 2 else {
                throw RouteError.noRouteFound
            }

            // Keep at most 49 stops after the start (including the destination).
            // Round an adjusted interval up to 100 m so it can be shown clearly in the picker.
            let minimumIntervalForStopLimit = ceil((routeLength / 49) / 100) * 100
            let effectiveStopInterval = max(stopInterval, minimumIntervalForStopLimit)

            var generated = [MapWaypoint(coordinate: origin, title: "Current Location")]
            var targetDistance = effectiveStopInterval
            var segmentIndex = 0
            var segmentStartDistance = 0.0
            var stopNumber = 1

            while targetDistance < routeLength {
                while segmentIndex < segmentLengths.count - 1,
                      segmentStartDistance + segmentLengths[segmentIndex] < targetDistance {
                    segmentStartDistance += segmentLengths[segmentIndex]
                    segmentIndex += 1
                }
                let segmentLength = segmentLengths[segmentIndex]
                if segmentLength > 0 {
                    let fraction = (targetDistance - segmentStartDistance) / segmentLength
                    let start = coordinates[segmentIndex]
                    let end = coordinates[segmentIndex + 1]
                    let stopCoordinate = CLLocationCoordinate2D(
                        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                        longitude: start.longitude + (end.longitude - start.longitude) * fraction
                    )
                    generated.append(MapWaypoint(coordinate: stopCoordinate, title: "Stop \(stopNumber)"))
                    stopNumber += 1
                }
                targetDistance += effectiveStopInterval
            }
            generated.append(MapWaypoint(coordinate: destination, title: destinationTitle ?? "Destination"))

            waypoints = generated
            cacheGeneration += 1
            legCache.removeAll()
            routingRevision += 1
            savedRoute = nil
            isRefreshingSavedRoute = false
            hasSetDefaultStart = true
            avoidHighwaysForCurrentRoute = !expressMode
            saveMessage = "Generated \(max(generated.count - 1, 0)) stops after the start. Calculating estimates…"
            return effectiveStopInterval
        } catch {
            if Task.isCancelled { return nil }
            errorMessage = "Could not generate route: \(error.localizedDescription)"
            saveMessage = nil
            return nil
        }
    }

    func loadSavedRoute(_ route: SavedRoute) {
        avoidHighwaysForCurrentRoute = false
        waypoints = route.waypoints.map {
            MapWaypoint(
                id: $0.id,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                title: $0.title
            )
        }
        routingRevision += 1
        cacheGeneration += 1
        legCache.removeAll()
        savedRoute = route
        errorMessage = nil
        saveMessage = "Loaded route \(route.routeNumber). Refreshing ETAs…"
        isRefreshingSavedRoute = true
        hasSetDefaultStart = true
    }

    func saveRoute(routeNumber: String, name: String, color: SavedRouteColor) {
        let trimmedNumber = routeNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNumber.isEmpty, !trimmedName.isEmpty, hasCompleteRoute else { return }

        let departure = Date()
        var elapsed: TimeInterval = 0
        var savedWaypoints: [SavedWaypoint] = []
        for (index, waypoint) in waypoints.enumerated() {
            let legTime: TimeInterval?
            if index == 0 {
                legTime = nil
            } else {
                guard let estimatedTime = estimatedLegTime(at: index) else { return }
                legTime = estimatedTime
                elapsed += estimatedTime
            }
            savedWaypoints.append(SavedWaypoint(
                id: waypoint.id,
                coordinate: waypoint.coordinate,
                title: waypoint.title,
                travelTimeFromPrevious: legTime,
                estimatedArrival: departure.addingTimeInterval(elapsed)
            ))
        }

        var routeCoordinates: [SavedCoordinate] = []
        for leg in legs {
            let pointCount = leg.polyline.pointCount
            guard pointCount >= 2 else { continue }
            let points = leg.polyline.points()
            for index in 0..<pointCount {
                let coordinate = points[index].coordinate
                if let previous = routeCoordinates.last {
                    let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                    let currentLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    if previousLocation.distance(from: currentLocation) < 1 { continue }
                }
                routeCoordinates.append(SavedCoordinate(coordinate))
            }
        }
        guard routeCoordinates.count >= 2 else {
            saveMessage = "Could not save route: route geometry is unavailable."
            return
        }

        let route = SavedRoute(
            routeNumber: trimmedNumber,
            name: trimmedName,
            color: color,
            savedAt: departure,
            waypoints: savedWaypoints,
            polyline: routeCoordinates
        )
        do {
            try SavedRouteStore.append(route)
            savedRoute = route
            saveMessage = "Saved route \(trimmedNumber), “\(trimmedName)” on this iPhone."
        } catch {
            saveMessage = "Could not save route: \(error.localizedDescription)"
        }
    }

    func removeWaypoint(_ waypoint: MapWaypoint) {
        waypoints.removeAll { $0.id == waypoint.id }
        legCache = legCache.filter { $0.key.from != waypoint.id && $0.key.to != waypoint.id }
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
    }

    func removeAll() {
        resetDraft(defaultStart: nil)
    }

    func resetDraft(defaultStart: CLLocationCoordinate2D?) {
        routingRevision += 1
        cacheGeneration += 1
        avoidHighwaysForCurrentRoute = false
        waypoints.removeAll()
        legCache.removeAll()
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
        hasSetDefaultStart = false
        if let defaultStart {
            setDefaultStart(at: defaultStart)
        }
    }

    // MARK: - Route calculation

    /// Fetches every missing leg, one request at a time (Apple Maps throttles bursts).
    /// Safe to call again: finished legs are cached, and a cancelled call just stops.
    func updateRoute() async {
        errorMessage = nil
        let generation = cacheGeneration

        let missingPairs = zip(waypoints, waypoints.dropFirst()).filter { pair in
            legCache[LegKey(from: pair.0.id, to: pair.1.id)] == nil
        }

        for pair in missingPairs {
            do {
                let leg = try await fetchLeg(from: pair.0, to: pair.1)
                guard generation == cacheGeneration else { return }
                legCache[leg.key] = leg          // keep it even if we were cancelled meanwhile
            } catch {
                if Task.isCancelled { return }
                errorMessage = message(for: error)
                if isRefreshingSavedRoute {
                    isRefreshingSavedRoute = false
                    saveMessage = "Route loaded, but its ETAs could not be refreshed."
                }
                return
            }
            if Task.isCancelled { return }
        }

        if isRefreshingSavedRoute && hasCompleteRoute {
            isRefreshingSavedRoute = false
            saveMessage = "Loaded route \(savedRoute?.routeNumber ?? ""). ETAs refreshed."
        }
    }

    private static func coordinates(in polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }
        let points = polyline.points()
        return (0..<polyline.pointCount).map { points[$0].coordinate }
    }

    private func fetchLeg(from start: MapWaypoint, to end: MapWaypoint) async throws -> DrivingLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = .automobile
        request.highwayPreference = avoidHighwaysForCurrentRoute ? .avoid : .any
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
