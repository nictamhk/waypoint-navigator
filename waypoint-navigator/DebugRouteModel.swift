import SwiftUI
import MapKit
import NavigationCore

/// Debug model: tap origin and destination, Build, then simulate a drive (Phase 3).
/// The corridor route -> stops -> per-leg routes pipeline is the one Phase 2 will fill in.
@MainActor
@Observable
final class DebugRouteModel {
    struct StopRow: Identifiable {
        let id: UUID
        let title: String
        let detail: String
        let coordinate: GeoCoordinate
    }

    struct Probe {
        let coordinate: GeoCoordinate
        let text: String
    }

    // Route building
    var origin: GeoCoordinate?
    var destination: GeoCoordinate?
    var interiorStopCount = 4
    var automaticStopInterval = 500.0
    var snapshot: RouteSnapshot?
    var status = "Tap the map to set the origin, then the destination."
    var isBuilding = false
    var probeChainage = 0.0
    var camera: MapCameraPosition = .automatic

    // Drive simulation
    var useLiveGPS = false
    var addJitter = true
    var addDropout = false
    var replaySpeed = 10.0
    var isDriving = false
    var latest: RouteMatchingService.Observation?
    var rawFix: LocationFix?
    var signal: SignalState = .acquiring
    var acceptedCount = 0
    var rejectedCount = 0

    private let manager: RouteManager
    private let osmProvider = OSMFeatureProvider()
    private var service: RouteMatchingService?
    private var driveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastFixWall = Date()

    init() {
        let store = try? FileSnapshotStore.defaultStore()
        manager = RouteManager(provider: MapKitDirectionsProvider(), store: store)
    }

    var canBuild: Bool { origin != nil && destination != nil && !isBuilding }

    func handleTap(_ coordinate: GeoCoordinate) {
        if origin == nil {
            origin = coordinate
            status = "Origin set. Tap the destination."
        } else if destination == nil {
            destination = coordinate
            status = "Destination set. Tap Build."
        } else {
            stopDrive()
            origin = coordinate
            destination = nil
            snapshot = nil
            probeChainage = 0
            status = "Origin reset. Tap the destination."
        }
    }

    // MARK: Route building

    func build() async {
        guard let origin, let destination else { return }
        stopDrive()
        isBuilding = true
        defer { isBuilding = false }
        do {
            let departure = Date()
            let start = Waypoint(coordinate: origin, name: LocalizedText("Origin", language: "en"), source: .origin)
            let end = Waypoint(coordinate: destination, name: LocalizedText("Destination", language: "en"), source: .destination)

            status = "Fetching corridor route..."
            let corridor = try await manager.buildSnapshot(waypoints: [start, end], plannedDeparture: departure)

            status = "Loading OSM stop and highway features..."
            let osm = try await osmProvider.features(for: corridor.geometry)
            let placement = StopPlacementService.generate(
                geometry: corridor.geometry,
                interval: automaticStopInterval,
                features: osm.features,
                highwayWays: osm.highwayWays
            )
            let waypoints = placement.stops.enumerated().map { index, stop in
                let isOrigin = index == 0
                let isDestination = index == placement.stops.count - 1
                let label = isOrigin ? "Origin" : (isDestination ? "Destination" : (stop.name ?? "Stop \(index)"))
                return Waypoint(
                    coordinate: stop.coordinate,
                    name: LocalizedText(label, language: "en"),
                    source: isOrigin ? .origin : (isDestination ? .destination : .generated),
                    nameSource: stop.name == nil ? .placeholder : .landmark
                )
            }

            status = "Fetching \(waypoints.count - 1) legs..."
            let result = try await manager.buildSnapshot(
                waypoints: waypoints, plannedDeparture: departure,
                progress: { done, total in
                    Task { @MainActor in self.status = "Fetched leg \(done) of \(total)..." }
                })
            snapshot = result
            probeChainage = 0
            camera = Self.frame(result.geometry.vertices)
            status = "Route \(Int(result.geometry.totalLength.rounded())) m, \(result.stops.count - 2) automatic stops (\(Int(placement.effectiveInterval.rounded())) m interval)."
        } catch {
            status = "Failed: \(error)"
        }
    }

    var stopRows: [StopRow] {
        guard let snapshot else { return [] }
        return snapshot.stops.map { stop in
            let waypoint = snapshot.waypoints[stop.index]
            return StopRow(
                id: stop.waypointID,
                title: waypoint.name.resolved(preferring: ["en"]) ?? "Stop",
                detail: "\(Int(stop.chainage.rounded())) m \u{2022} \(stop.baselineArrival.formatted(date: .omitted, time: .shortened))",
                coordinate: waypoint.coordinate)
        }
    }

    /// Moves a fake position along the route and checks the chainage maths round-trips.
    var probe: Probe? {
        guard let snapshot, !isDriving else { return nil }
        let coordinate = snapshot.geometry.coordinate(atChainage: probeChainage)
        guard let projection = snapshot.geometry.project(coordinate) else { return nil }
        let error = abs(projection.chainage - probeChainage)
        guard let next = snapshot.stops.first(where: { $0.chainage > projection.chainage + 0.5 }) else {
            return Probe(coordinate: coordinate, text: String(format: "Chainage %.0f m (round-trip error %.2f m) \u{2022} at destination", projection.chainage, error))
        }
        let name = snapshot.waypoints[next.index].name.resolved(preferring: ["en"]) ?? "stop"
        let eta = next.baselineArrival.formatted(date: .omitted, time: .shortened)
        return Probe(coordinate: coordinate, text: String(
            format: "Chainage %.0f m (round-trip error %.2f m) \u{2022} next: %@ in %.0f m, planned %@",
            projection.chainage, error, name, next.chainage - projection.chainage, eta))
    }

    // MARK: Drive simulation

    func startDrive() {
        guard let snapshot else { return }
        stopDrive()
        service = RouteMatchingService(geometry: snapshot.geometry)
        latest = nil
        rawFix = nil
        signal = .acquiring
        acceptedCount = 0
        rejectedCount = 0

        let live = useLiveGPS
        let multiplier = live ? 1.0 : replaySpeed
        let source: any LocationServicing
        if live {
            source = CoreLocationService()
        } else {
            let track = TrackBuilder.along(snapshot.geometry, speed: 12, interval: 1)
            var faults = ReplayLocationService.Faults()
            if addJitter { faults.jitterSigma = 5 }
            if addDropout {
                let start = Double(track.count) * 0.4
                faults.dropouts = [start...(start + 20)]
            }
            source = ReplayLocationService(track: track, speedMultiplier: replaySpeed, faults: faults)
        }

        isDriving = true
        lastFixWall = Date()
        driveTask = Task { [weak self] in
            for await fix in source.fixStream() {
                guard let self, !Task.isCancelled else { break }
                self.handle(fix, live: live)
            }
            self?.isDriving = false
        }
        // Watchdog: signal loss is noticed even when no fixes arrive.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tick(live: live, multiplier: multiplier)
            }
        }
    }

    func stopDrive() {
        driveTask?.cancel()
        tickTask?.cancel()
        driveTask = nil
        tickTask = nil
        isDriving = false
    }

    private func handle(_ fix: LocationFix, live: Bool) {
        guard var current = service else { return }
        let observation = current.ingest(fix, now: live ? Date() : nil)
        service = current
        lastFixWall = Date()
        rawFix = fix
        latest = observation
        signal = observation.signal
        if case .rejected = observation.verdict { rejectedCount += 1 } else { acceptedCount += 1 }
    }

    private func tick(live: Bool, multiplier: Double) {
        guard var current = service, let fix = rawFix else { return }
        let now = live ? Date() : fix.timestamp.addingTimeInterval(Date().timeIntervalSince(lastFixWall) * multiplier)
        signal = current.tick(now: now)
        service = current
    }

    var driveStatus: String {
        guard let observation = latest else { return isDriving ? "Waiting for the first fix..." : "" }
        var lines: [String] = []
        lines.append("signal \(signal.rawValue) \u{2022} fix \(describe(observation.verdict)) \u{2022} accepted \(acceptedCount), rejected \(rejectedCount)")
        if let match = observation.match {
            lines.append(String(format: "chainage %.0f m \u{2022} progress %.0f m \u{2022} speed %.1f m/s", match.chainage, match.progress, match.alongSpeed))
            let heading = match.headingDelta.map { String(format: "%.0f\u{00B0}", $0) } ?? "n/a"
            lines.append(String(format: "lateral %+.1f m \u{2022} heading \u{0394} %@ \u{2022} confidence %@ \u{2022} reversing %@ \u{2022} reliable %@",
                                match.lateralOffset, heading, match.confidence.rawValue,
                                match.isReversing ? "yes" : "no", observation.isReliable ? "yes" : "no"))
            if let snapshot, let next = snapshot.stops.first(where: { $0.chainage > match.progress + 1 }) {
                let name = snapshot.waypoints[next.index].name.resolved(preferring: ["en"]) ?? "stop"
                lines.append(String(format: "next: %@ in %.0f m", name, next.chainage - match.progress))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ verdict: LocationQualityFilter.Verdict) -> String {
        switch verdict {
        case .good: return "good"
        case .degraded: return "degraded"
        case .rejected(let reason): return "rejected (\(reason.rawValue))"
        }
    }

    private static func frame(_ coordinates: [GeoCoordinate]) -> MapCameraPosition {
        let latitudes = coordinates.map(\.latitude), longitudes = coordinates.map(\.longitude)
        guard let minLat = latitudes.min(), let maxLat = latitudes.max(),
              let minLon = longitudes.min(), let maxLon = longitudes.max() else { return .automatic }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.005),
                                    longitudeDelta: max((maxLon - minLon) * 1.3, 0.005))
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}
