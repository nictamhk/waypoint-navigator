import Foundation
import CryptoKit

public enum OSMFeatureProviderError: Error { case invalidResponse, httpStatus(Int) }

/// Fetches stop candidates and highway ways from the public Overpass API.
///
/// - The route is split into chunks of about 25 km. Each chunk is one request, sent one at a time with a
///   pause between requests, and only asks for features near that part of the route (an `around` filter on
///   the simplified polyline), not for the whole bounding box.
/// - Responses are cached on disk for 30 days, so regenerating a route does not hit the server again.
/// - HTTP 429 and 504 are retried once after 30 s. A chunk that still fails is reported in
///   `degradedRanges` (chainage in metres) and the other chunks are still used.
public struct OSMFeatureProvider: Sendable {
    public var endpoint: URL
    public var session: URLSession
    /// Overpass asks clients to identify themselves. Put a contact address here before any wider use.
    public var userAgent: String

    public init(endpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!,
                session: URLSession = .shared,
                userAgent: String = "waypoint-navigator/0.1 (iOS prototype)") {
        self.endpoint = endpoint; self.session = session; self.userAgent = userAgent
    }

    // MARK: - Public API

    /// `corridorRadius` nil (the default) uses the automatic per-kind radii and names intersections by their
    /// cross street. A value is used for every kind and is meant for `stopName(near:)`, where there is no
    /// real route.
    public func features(for geometry: RouteGeometry, corridorRadius: Double? = nil) async throws
        -> (features: [StopFeature], highwayWays: [HighwayWay], degradedRanges: [ClosedRange<Double>], roads: [NamedRoad]) {
        guard geometry.vertices.count >= 2 else { return ([], [], [], []) }
        let radii = corridorRadius.map { SearchRadii.uniform(max($0, 1)) } ?? SearchRadii.automatic
        let routeAware = corridorRadius == nil
        let chunks = Self.chunks(of: geometry.vertices)

        var features: [String: StopFeature] = [:]
        var ways: [String: HighwayWay] = [:]
        var routeRoads: [String: NamedRoad] = [:]
        var degraded: [ClosedRange<Double>] = []
        var lastError: Error?
        var succeeded = 0

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let query = Self.query(for: chunk, radii: radii)
            do {
                let (data, fromNetwork) = try await responseData(for: query)
                let parsed = try Self.parse(data, chunk: chunk, geometry: geometry, routeAware: routeAware)
                if fromNetwork { Self.storeResponse(data, for: query) }
                for feature in parsed.features where features[feature.id] == nil { features[feature.id] = feature }
                for way in parsed.ways where ways[way.id] == nil { ways[way.id] = way }
                for road in parsed.roads where routeRoads[road.id] == nil { routeRoads[road.id] = road }
                succeeded += 1
                if fromNetwork, index < chunks.count - 1 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                lastError = error
                degraded.append(chunk.startChainage...chunk.endChainage)
            }
        }
        if succeeded == 0, let lastError { throw lastError }
        return (features.values.sorted { $0.id < $1.id },
                ways.values.sorted { $0.id < $1.id },
                degraded,
                routeRoads.values.sorted { $0.id < $1.id })
    }

    /// Returns the highest-priority named OSM stop feature near a manually added waypoint.
    public func stopName(near coordinate: GeoCoordinate, searchRadius: Double = 100) async throws -> String? {
        let latitudeOffset = searchRadius / 111_000
        let geometry = RouteGeometry(
            vertices: [
                GeoCoordinate(latitude: coordinate.latitude - latitudeOffset, longitude: coordinate.longitude),
                GeoCoordinate(latitude: coordinate.latitude + latitudeOffset, longitude: coordinate.longitude)
            ],
            legEndVertexIndices: []
        )
        let result = try await features(for: geometry, corridorRadius: searchRadius)
        let candidates = result.features.compactMap { feature -> (StopFeature, Double)? in
            let distance = coordinate.distance(to: feature.coordinate)
            guard feature.kind != .highwayExit else { return nil }
            guard let name = resolvedName(for: feature), !name.isEmpty else { return nil }
            let allowedDistance: Double
            switch feature.kind {
            case .busStop, .trainMetroStation, .signalizedMajorIntersection, .minorIntersection: allowedDistance = 50
            case .landmark: allowedDistance = 100
            case .highwayExit: allowedDistance = 0
            }
            guard distance <= allowedDistance else { return nil }
            return (feature, distance)
        }
        guard let selected = candidates.sorted(by: { lhs, rhs in
            let lhsPriority = namingPriority(lhs.0.kind), rhsPriority = namingPriority(rhs.0.kind)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            return lhs.0.id < rhs.0.id
        }).first else { return nil }
        return resolvedName(for: selected.0)
    }

    // MARK: - Search radii

    private struct SearchRadii {
        let busStop: Double, signal: Double, exit: Double, landmark: Double, road: Double
        static let automatic = SearchRadii(busStop: 60, signal: 25, exit: 40, landmark: 150, road: 25)
        static func uniform(_ radius: Double) -> SearchRadii {
            SearchRadii(busStop: radius, signal: radius, exit: radius, landmark: radius, road: radius)
        }
    }

    // MARK: - Chunking and simplification

    private struct RouteChunk {
        let coordinates: [GeoCoordinate]   // simplified
        let tolerance: Double              // metres; added to every search radius
        let startChainage: Double
        let endChainage: Double
    }

    private static func chunks(of vertices: [GeoCoordinate], length: Double = 25_000, overlap: Double = 100) -> [RouteChunk] {
        var cumulative = [0.0]
        cumulative.reserveCapacity(vertices.count)
        for i in 1..<vertices.count {
            cumulative.append(cumulative[i - 1] + vertices[i - 1].distance(to: vertices[i]))
        }
        var result: [RouteChunk] = []
        var start = 0
        while start < vertices.count - 1 {
            var end = start + 1
            while end < vertices.count - 1, cumulative[end] - cumulative[start] < length { end += 1 }
            let (simplified, tolerance) = simplify(Array(vertices[start...end]))
            result.append(RouteChunk(coordinates: simplified, tolerance: tolerance,
                                     startChainage: cumulative[start], endChainage: cumulative[end]))
            if end >= vertices.count - 1 { break }
            var next = end
            while next > start + 1, cumulative[end] - cumulative[next - 1] <= overlap { next -= 1 }
            start = max(next, start + 1)
        }
        return result
    }

    /// Douglas-Peucker with a tolerance that grows until the polyline has at most `maxPoints` points
    /// (long queries are slow). The tolerance is returned so the search radius can be widened by it.
    private static func simplify(_ points: [GeoCoordinate], maxPoints: Int = 300) -> ([GeoCoordinate], Double) {
        var tolerance = 15.0
        var result = douglasPeucker(points, tolerance)
        while result.count > maxPoints, tolerance < 500 {
            tolerance *= 1.5
            result = douglasPeucker(points, tolerance)
        }
        return (result, tolerance)
    }

    private static func douglasPeucker(_ points: [GeoCoordinate], _ tolerance: Double) -> [GeoCoordinate] {
        guard points.count > 2 else { return points }
        let originLatitude = points[0].latitude, originLongitude = points[0].longitude
        let kx = 111_320 * cos(originLatitude * .pi / 180), ky = 110_540.0
        let xy: [(x: Double, y: Double)] = points.map {
            (($0.longitude - originLongitude) * kx, ($0.latitude - originLatitude) * ky)
        }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (low, high) = stack.popLast() {
            guard high > low + 1 else { continue }
            let a = xy[low], b = xy[high]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var farthest = 0.0
            var farthestIndex = -1
            for i in (low + 1)..<high {
                let p = xy[i]
                var t = lengthSquared > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared : 0
                t = min(max(t, 0), 1)
                let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
                if d > farthest { farthest = d; farthestIndex = i }
            }
            if farthestIndex >= 0, farthest > tolerance {
                keep[farthestIndex] = true
                stack.append((low, farthestIndex))
                stack.append((farthestIndex, high))
            }
        }
        return zip(points, keep).filter { $0.1 }.map { $0.0 }
    }

    // MARK: - Query

    private static func query(for chunk: RouteChunk, radii: SearchRadii) -> String {
        let line = chunk.coordinates
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }
            .joined(separator: ",")
        func around(_ radius: Double) -> String { "(around:\(Int((radius + chunk.tolerance).rounded())),\(line))" }
        let landmarkFilters = [
            "[amenity~\"^(hospital|school|college|university|library|townhall|place_of_worship)$\"]",
            "[shop=mall]",
            "[tourism~\"^(attraction|museum|viewpoint)$\"]",
            "[historic]"
        ]
        var points = "node\(around(radii.busStop))[highway=bus_stop];"
        points += "node\(around(radii.busStop))[public_transport=platform][bus=yes];"
        points += "nwr\(around(radii.landmark))[railway=station];"
        points += "nwr\(around(radii.landmark))[public_transport=station][station~\"^(train|subway|metro)$\"];"
        points += "node\(around(radii.signal))[highway=traffic_signals];"
        points += "node\(around(radii.exit))[highway=motorway_junction];"
        for filter in landmarkFilters { points += "nwr\(around(radii.landmark))\(filter);" }
        let roads = "way\(around(radii.road))[highway~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential)$\"];"
        return "[out:json][timeout:60];(\(points));out center tags;(\(roads));out geom tags;"
    }

    // MARK: - Network, retry and cache

    private func responseData(for query: String) async throws -> (data: Data, fromNetwork: Bool) {
        if let cached = Self.cachedResponse(for: query) { return (cached, false) }
        var retried = false
        while true {
            var request = URLRequest(url: endpoint, timeoutInterval: 70)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = Data(("data=" + Self.formEncoded(query)).utf8)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw OSMFeatureProviderError.invalidResponse }
            if (http.statusCode == 429 || http.statusCode == 504), !retried {
                retried = true
                try await Task.sleep(nanoseconds: 30_000_000_000)
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw OSMFeatureProviderError.httpStatus(http.statusCode) }
            return (data, true)
        }
    }

    private static func formEncoded(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("overpass", isDirectory: true)
    }

    private static func cacheURL(for query: String) -> URL {
        let digest = SHA256.hash(data: Data(query.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".json")
    }

    private static func cachedResponse(for query: String) -> Data? {
        let url = cacheURL(for: query)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < 30 * 24 * 3600 else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func storeResponse(_ data: Data, for query: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: query), options: .atomic)
    }

    // MARK: - Parsing

    private struct VertexKey: Hashable {
        let lat: Int, lon: Int
        init(_ c: GeoCoordinate) {
            lat = Int((c.latitude * 1e7).rounded())
            lon = Int((c.longitude * 1e7).rounded())
        }
    }

    private struct RoadWay {
        let id: String
        let highway: String
        let names: [String: String]
        let coordinates: [GeoCoordinate]
        var isRouteWay = false
    }

    private static let roadClasses: Set<String> = [
        "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential"
    ]
    private static let majorCrossClasses: Set<String> = ["trunk", "primary", "secondary"]

    private static func classRank(_ highway: String) -> Int {
        switch highway {
        case "trunk": return 1
        case "primary": return 2
        case "secondary": return 3
        case "tertiary": return 4
        case "unclassified": return 5
        default: return 6
        }
    }

    private static func parse(_ data: Data, chunk: RouteChunk, geometry: RouteGeometry, routeAware: Bool)
        throws -> (features: [StopFeature], ways: [HighwayWay], roads: [NamedRoad]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw OSMFeatureProviderError.invalidResponse }

        var features: [StopFeature] = []
        var highwayWays: [HighwayWay] = []
        var signals = Set<VertexKey>()
        var roads: [RoadWay] = []

        for item in elements {
            guard let id = item["id"] as? Int else { continue }
            let type = item["type"] as? String ?? "node"
            let tags = item["tags"] as? [String: String] ?? [:]

            // Roads come back with their geometry.
            if type == "way", let highway = tags["highway"], roadClasses.contains(highway),
               let shape = item["geometry"] as? [[String: Double]] {
                let coordinates = shape.compactMap { point -> GeoCoordinate? in
                    guard let lat = point["lat"], let lon = point["lon"] else { return nil }
                    return GeoCoordinate(latitude: lat, longitude: lon)
                }
                guard coordinates.count >= 2 else { continue }
                if highway == "motorway" || highway == "trunk" {
                    highwayWays.append(HighwayWay(id: "way/\(id)", coordinates: coordinates, highway: highway,
                                                  expressway: tags["expressway"] == "yes"))
                }
                roads.append(RoadWay(id: "way/\(id)", highway: highway, names: localizedNames(tags), coordinates: coordinates))
                continue
            }

            // Everything else is a point or has a centre (landmark buildings).
            let coordinate: GeoCoordinate
            if let lat = item["lat"] as? Double, let lon = item["lon"] as? Double {
                coordinate = GeoCoordinate(latitude: lat, longitude: lon)
            } else if let center = item["center"] as? [String: Double], let lat = center["lat"], let lon = center["lon"] {
                coordinate = GeoCoordinate(latitude: lat, longitude: lon)
            } else { continue }

            let names = localizedNames(tags)
            let featureID = "\(type)/\(id)"
            if tags["highway"] == "motorway_junction" {
                features.append(StopFeature(id: featureID, coordinate: coordinate, kind: .highwayExit,
                                            name: tags["name"], ref: tags["ref"],
                                            detail: [tags["exit_to"], tags["destination"]]
                                                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                .filter { !$0.isEmpty }
                                                .joined(separator: " · "), names: names))
            } else if tags["highway"] == "traffic_signals" {
                signals.insert(VertexKey(coordinate))
            } else if isBusStop(tags), let name = names["default"] {
                features.append(StopFeature(id: featureID, coordinate: coordinate, kind: .busStop,
                                            name: name, names: names))
            } else if isTrainOrMetroStation(tags), let name = names["default"] {
                features.append(StopFeature(id: featureID, coordinate: coordinate, kind: .trainMetroStation,
                                            name: name, names: names))
            } else if isLandmark(tags), let name = names["default"] {
                features.append(StopFeature(id: featureID, coordinate: coordinate, kind: .landmark,
                                            name: name, names: names))
            }
        }

        let intersections = intersections(roads: roads, signals: signals, chunk: chunk, geometry: geometry, routeAware: routeAware)
        features += intersections.features
        let namedRoads = intersections.routeRoads.compactMap { road -> NamedRoad? in
            guard let name = road.names["default"] else { return nil }
            return NamedRoad(id: road.id, name: name, highway: road.highway, coordinates: road.coordinates)
        }
        return (features, highwayWays, namedRoads)
    }

    private static func isBusStop(_ tags: [String: String]) -> Bool {
        tags["highway"] == "bus_stop" || (tags["public_transport"] == "platform" && tags["bus"] == "yes")
    }

    private static func isTrainOrMetroStation(_ tags: [String: String]) -> Bool {
        if tags["railway"] == "station" { return true }
        return tags["public_transport"] == "station"
            && ["train", "subway", "metro"].contains(tags["station"] ?? "")
    }

    private static func isLandmark(_ tags: [String: String]) -> Bool {
        if tags["shop"] == "mall" || tags["historic"] != nil { return true }
        if let tourism = tags["tourism"], ["attraction", "museum", "viewpoint"].contains(tourism) { return true }
        if let amenity = tags["amenity"],
           ["hospital", "school", "college", "university", "library", "townhall", "place_of_worship"].contains(amenity) { return true }
        return false
    }

    /// "default" holds the untagged name; `name:en`, `name:fr`, ... become "en", "fr", ...
    private static func localizedNames(_ tags: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in tags {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if key == "name" { result["default"] = trimmed }
            else if key.hasPrefix("name:") { result[String(key.dropFirst(5))] = trimmed }
        }
        return result
    }

    // MARK: Intersections

    /// Route-aware mode (automatic generation): a junction is where a way running along the route meets at
    /// least one other way; the stop is named after the cross street only. Major = signals or a
    /// trunk/primary/secondary cross street.
    /// Otherwise (naming a tapped point, no real route): any junction of two named roads, named "A & B".
    private static func intersections(roads inputRoads: [RoadWay], signals: Set<VertexKey>, chunk: RouteChunk,
                                      geometry: RouteGeometry, routeAware: Bool)
        -> (features: [StopFeature], routeRoads: [RoadWay]) {
        var roads = inputRoads
        let low = max(0, chunk.startChainage - 200)
        let high = min(geometry.totalLength, chunk.endChainage + 200)
        let canProject = routeAware && low <= high

        if canProject {
            for index in roads.indices {
                roads[index].isRouteWay = runsAlongRoute(roads[index].coordinates, geometry: geometry, window: low...high)
            }
        }

        var waysAtVertex: [VertexKey: Set<Int>] = [:]
        var coordinateAtVertex: [VertexKey: GeoCoordinate] = [:]
        for (index, road) in roads.enumerated() {
            for coordinate in road.coordinates {
                let key = VertexKey(coordinate)
                waysAtVertex[key, default: []].insert(index)
                coordinateAtVertex[key] = coordinate
            }
        }

        var result: [StopFeature] = []
        for (key, indices) in waysAtVertex where indices.count >= 2 {
            guard let coordinate = coordinateAtVertex[key] else { continue }
            let here = indices.sorted().map { roads[$0] }
            let ranked: ([RoadWay]) -> [RoadWay] = { list in
                list.filter { $0.names["default"] != nil }.sorted {
                    let a = classRank($0.highway), b = classRank($1.highway)
                    if a != b { return a < b }
                    return ($0.names["default"] ?? "") < ($1.names["default"] ?? "")
                }
            }

            let name: String
            var names: [String: String] = [:]
            let isMajor: Bool
            if canProject {
                let along = here.filter(\.isRouteWay), cross = here.filter { !$0.isRouteWay && $0.highway != "motorway" }
                guard !along.isEmpty, !cross.isEmpty,
                      let projection = geometry.project(coordinate, window: low...high), projection.distance <= 20,
                      let best = ranked(cross).first, let defaultName = best.names["default"] else { continue }
                name = defaultName
                names = best.names
                isMajor = signals.contains(key) || cross.contains { majorCrossClasses.contains($0.highway) }
            } else {
                var seenNames = Set<String>()
                let top = ranked(here).filter { seenNames.insert($0.names["default"] ?? "").inserted }.prefix(2)
                guard top.count == 2 else { continue }
                name = top.compactMap { $0.names["default"] }.joined(separator: " & ")
                isMajor = signals.contains(key) || here.contains { majorCrossClasses.contains($0.highway) }
            }
            names["default"] = name
            result.append(StopFeature(id: "intersection/\(key.lat),\(key.lon)", coordinate: coordinate,
                                      kind: isMajor ? .signalizedMajorIntersection : .minorIntersection,
                                      name: name, names: names))
        }
        return (result, roads.filter { $0.isRouteWay })
    }

    /// True if some segment of the way lies within 20 m of the route and runs within 30 degrees of it.
    private static func runsAlongRoute(_ coordinates: [GeoCoordinate], geometry: RouteGeometry,
                                       window: ClosedRange<Double>) -> Bool {
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let middle = GeoCoordinate(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
            guard let projection = geometry.project(middle, window: window), projection.distance <= 20 else { continue }
            let raw = abs(a.bearing(to: b) - geometry.bearing(atChainage: projection.chainage)).truncatingRemainder(dividingBy: 360)
            let difference = min(raw, 360 - raw)
            if min(difference, abs(180 - difference)) <= 30 { return true }
        }
        return false
    }

    // MARK: - Naming (manual waypoints)

    private func resolvedName(for feature: StopFeature) -> String? {
        let name = feature.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty { return name }
        if feature.kind == .highwayExit {
            let destination = feature.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let destination, !destination.isEmpty { return destination }
            let ref = feature.ref?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref, !ref.isEmpty { return "Exit \(ref)" }
        }
        return nil
    }

    /// Naming order for a tapped point: bus stop, cross street (major, then minor), landmark.
    private func namingPriority(_ kind: StopFeatureKind) -> Int {
        switch kind {
        case .busStop: return 0
        case .trainMetroStation: return 1
        case .signalizedMajorIntersection: return 2
        case .minorIntersection: return 3
        case .landmark: return 4
        case .highwayExit: return 5
        }
    }
}
