import MapKit
import Observation
import NavigationCore
import CoreLocation

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
    private let osmFeatureProvider = OSMFeatureProvider()
    private let addressResolver = AddressResolver()
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

    @discardableResult
    func addWaypoint(at coordinate: CLLocationCoordinate2D, title: String? = nil) -> UUID {
        let id = UUID()
        let initialTitle = title ?? "Stop \(waypoints.count)"
        waypoints.append(MapWaypoint(id: id, coordinate: coordinate, title: initialTitle))
        errorMessage = nil
        saveMessage = nil
        savedRoute = nil
        isRefreshingSavedRoute = false
        return id
    }

    func resolveWaypointName(id: UUID, fallback: String) async {
        guard let initial = waypoints.first(where: { $0.id == id }) else { return }
        let initialTitle = initial.title
        let resolvedName = await suggestedStopName(at: initial.coordinate)
        guard let current = waypoints.first(where: { $0.id == id }), current.title == initialTitle else { return }
        renameWaypoint(id: id, title: resolvedName ?? fallback)
    }

    func suggestedStopName(at coordinate: CLLocationCoordinate2D) async -> String? {
        if let name = try? await osmFeatureProvider.stopName(near: GeoCoordinate(coordinate)) { return name }
        return await reverseGeocodedAddress(at: coordinate)
    }

    private func reverseGeocodedAddress(at coordinate: CLLocationCoordinate2D) async -> String? {
        await addressResolver.address(at: coordinate)
    }

    func renameWaypoint(id: UUID, title: String) {
        guard let index = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = waypoints[index].title ?? "Stop \(index)"
        waypoints[index] = MapWaypoint(
            id: waypoints[index].id,
            coordinate: waypoints[index].coordinate,
            title: trimmed.isEmpty ? fallback : trimmed
        )
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

    /// Builds a drivable corridor, fetches nearby OSM features, places stops along it, then names them:
    /// OSM name first, otherwise a reverse-geocoded address. Titles are made unique within the route.
    /// The interval is a minimum spacing: stops only go at real features, so a rural road may have long gaps.
    /// If the OSM server cannot be reached at all, stops are placed at the interval and named from addresses.
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
            guard coordinates.count >= 2 else {
                throw RouteError.noRouteFound
            }

            let geometry = RouteGeometry(
                vertices: coordinates.map { GeoCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                legEndVertexIndices: []
            )
            guard geometry.totalLength > 0 else { throw RouteError.noRouteFound }

            saveMessage = "Loading nearby OSM stops and highway features…"
            var features: [StopFeature] = []
            var highwayWays: [HighwayWay] = []
            var notes: [String] = []
            var onlineDataFailed = false
            do {
                let osm = try await osmFeatureProvider.features(for: geometry)
                features = osm.features
                highwayWays = osm.highwayWays
                if !osm.degradedRanges.isEmpty {
                    notes.append("Online place data was unavailable for part of this route, so that stretch may have fewer stops.")
                }
            } catch {
                if Task.isCancelled { return nil }
                onlineDataFailed = true
                notes.append("Online place data was unavailable, so stops are placed at the interval and named from addresses.")
            }
            guard !Task.isCancelled else { return nil }

            let placement = StopPlacementService.generate(
                geometry: geometry,
                interval: stopInterval,
                features: features,
                highwayWays: highwayWays,
                expressMode: expressMode,
                addressFallback: onlineDataFailed
            )

            guard let generated = await makeWaypoints(from: placement.stops, origin: origin,
                                                      destination: destination,
                                                      destinationTitle: destinationTitle) else { return nil }

            waypoints = generated
            cacheGeneration += 1
            legCache.removeAll()
            routingRevision += 1
            savedRoute = nil
            isRefreshingSavedRoute = false
            hasSetDefaultStart = true
            avoidHighwaysForCurrentRoute = !expressMode

            var message = "Generated \(max(generated.count - 2, 0)) stops"
            if placement.wasAdjusted {
                message += ". Minimum spacing adjusted from \(Self.formatDistance(placement.requestedInterval)) to "
                    + "\(Self.formatDistance(placement.effectiveInterval)) to stay within "
                    + "\(StopPlacementService.targetStops) stops."
            } else {
                message += " with at least \(Self.formatDistance(placement.effectiveInterval)) between stops."
            }
            if !notes.isEmpty { message += " " + notes.joined(separator: " ") }
            saveMessage = message + " Calculating estimates…"
            return placement.effectiveInterval
        } catch {
            if Task.isCancelled { return nil }
            errorMessage = "Could not generate route: \(error.localizedDescription)"
            saveMessage = nil
            return nil
        }
    }

    /// Turns placed stops into waypoints.
    /// - Origin keeps "Current Location"; the destination uses the given title, else an OSM/address name.
    /// - Feature names follow StopPlacementService's priority (bus stop, cross street, landmark, exit).
    /// - Unnamed stops are reverse-geocoded; if that fails they remain as "Stop X".
    /// - Finally titles are made unique (later duplicates get a km marker).
    private func makeWaypoints(from placed: [PlacedStop],
                               origin: CLLocationCoordinate2D,
                               destination: CLLocationCoordinate2D,
                               destinationTitle: String?) async -> [MapWaypoint]? {
        struct Draft {
            var title: String?
            var names: [String: String]
            var coordinate: CLLocationCoordinate2D
            var chainage: Double
        }
        var drafts: [Draft] = []
        let addressCount = placed.dropFirst().dropLast().count
        var addressesDone = 0

        for (index, stop) in placed.enumerated() {
            let coordinate = CLLocationCoordinate2D(latitude: stop.coordinate.latitude,
                                                    longitude: stop.coordinate.longitude)
            if index == 0 {
                drafts.append(Draft(title: "Current Location", names: [:], coordinate: origin, chainage: stop.chainage))
            } else if index == placed.count - 1 {
                var title = destinationTitle
                if title == nil { title = await suggestedStopName(at: destination) }
                guard !Task.isCancelled else { return nil }
                drafts.append(Draft(title: title ?? "Destination", names: [:], coordinate: destination,
                                    chainage: stop.chainage))
            } else {
                addressesDone += 1
                saveMessage = "Naming stops (\(addressesDone) of \(addressCount))…"
                var title = StopNaming.title(name: stop.name, detail: stop.detail)
                if title == nil {
                    title = await addressResolver.address(at: coordinate)
                }
                guard !Task.isCancelled else { return nil }
                drafts.append(Draft(title: title,
                                    names: stop.names, coordinate: coordinate, chainage: stop.chainage))
            }
        }

        var items: [(title: String, chainage: Double)] = []
        for (index, draft) in drafts.enumerated() {
            items.append((title: draft.title ?? "Stop \(index)", chainage: draft.chainage))
        }
        let titles = StopNaming.makeUnique(items)
        return drafts.enumerated().map { index, draft in
            // If a title had to be changed to stay unique, drop the per-language names so announcements
            // use the unique title instead of repeating the same name twice.
            let changed = titles[index] != items[index].title
            return MapWaypoint(coordinate: draft.coordinate, title: titles[index],
                               names: changed ? [:] : draft.names)
        }
    }

    private static func formatDistance(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.1f km", meters / 1_000) : "\(Int(meters.rounded())) m"
    }

    func loadSavedRoute(_ route: SavedRoute) {
        avoidHighwaysForCurrentRoute = false
        waypoints = route.waypoints.map {
            MapWaypoint(
                id: $0.id,
                coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude),
                title: $0.title,
                names: $0.names
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
                estimatedArrival: departure.addingTimeInterval(elapsed),
                names: waypoint.names
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
