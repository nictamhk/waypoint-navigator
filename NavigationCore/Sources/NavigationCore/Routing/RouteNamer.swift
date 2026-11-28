import Foundation

// Route naming. Pure logic (no network, no MapKit) so it can be unit-tested.
//
// Order of rules:
//  1. One road covers more than 80% of the named route length  -> that road ("King")
//  2. Two roads together cover more than 80%                   -> "Longer — Shorter"
//  3. At least 50% of the stops share one neighbourhood        -> that neighbourhood
//  4. Fallback: the destination's assigned name; if it has none -> "Route 3"
//  Finally, if a highway carries most of the route, " Express" is added to whatever name was chosen.

// MARK: - Street names

public enum StreetNameFormatter {
    /// Road types and directions dropped from the END of a name ("King Street East" -> "King").
    private static let trailingWords: Set<String> = [
        // directions (English and French)
        "north", "south", "east", "west", "n", "s", "e", "w", "ne", "nw", "se", "sw",
        "nord", "sud", "est", "ouest",
        // road types
        "street", "st", "avenue", "ave", "av", "road", "rd", "drive", "dr", "boulevard", "blvd", "boul",
        "crescent", "cres", "court", "ct", "lane", "ln", "way", "place", "pl", "terrace", "terr",
        "trail", "trl", "parkway", "pkwy", "line", "circle", "cir", "gate", "heights", "square",
        "grove", "close", "expressway", "expy", "freeway", "fwy"
    ]
    /// French road types that come first ("Rue Sainte-Catherine" -> "Sainte-Catherine").
    private static let leadingTypes: Set<String> = ["rue", "chemin", "boulevard", "boul", "montée", "montee"]
    private static let particles: [String] = ["de", "du", "des", "la", "le", "les", "l'", "l’", "d'", "d’"]

    /// Drops the road type and direction. Never reduces a name to nothing, so "Avenue Road" -> "Avenue".
    /// Names such as "Highway 7" or "County Road 5" are left alone because they end in a number.
    public static func baseName(_ name: String) -> String {
        var tokens = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return "" }
        while tokens.count > 1, let last = tokens.last, trailingWords.contains(normalized(last)) {
            tokens.removeLast()
        }
        if tokens.count > 1, leadingTypes.contains(normalized(tokens[0])) {
            // Keep "Chemin de la Côte-des-Neiges" intact: dropping "Chemin" would leave "de la ...".
            let next = normalized(tokens[1])
            let startsWithParticle = particles.contains { particle in
                particle.hasSuffix("'") || particle.hasSuffix("’") ? next.hasPrefix(particle) : next == particle
            }
            if !startsWithParticle { tokens.removeFirst() }
        }
        return tokens.joined(separator: " ")
    }

    /// Key used to treat "King Street East" and "King St W" as the same road.
    public static func groupingKey(_ baseName: String) -> String {
        baseName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ".,")).lowercased()
    }
}

// MARK: - Road coverage

/// A named road that runs along the route (from `OSMFeatureProvider`).
public struct NamedRoad: Sendable, Equatable {
    public let id: String
    public let name: String
    public let highway: String
    public let coordinates: [GeoCoordinate]

    public init(id: String, name: String, highway: String, coordinates: [GeoCoordinate]) {
        self.id = id; self.name = name; self.highway = highway; self.coordinates = coordinates
    }
}

public struct RoadStretch: Sendable, Equatable {
    /// Display name with the road type dropped.
    public let name: String
    public let meters: Double
    public init(name: String, meters: Double) { self.name = name; self.meters = meters }
}

public struct RoadCoverage: Sendable, Equatable {
    /// Sorted by distance, longest first.
    public let stretches: [RoadStretch]
    public let namedMeters: Double
    public let totalMeters: Double
    public init(stretches: [RoadStretch], namedMeters: Double, totalMeters: Double) {
        self.stretches = stretches; self.namedMeters = namedMeters; self.totalMeters = totalMeters
    }
}

// MARK: - Neighbourhoods

/// Counts neighbourhood names (Apple's `subLocality`) across a route's stops, one stop at a time, so the caller
/// can stop reverse-geocoding as soon as the outcome is certain.
public struct NeighbourhoodTally: Sendable {
    public let totalStops: Int
    public private(set) var answered = 0
    private var counts: [String: Int] = [:]
    private var display: [String: String] = [:]

    public init(totalStops: Int) { self.totalStops = max(totalStops, 0) }

    /// Record one stop's neighbourhood. Pass nil (or an empty string) if the stop had none.
    public mutating func add(_ neighbourhood: String?) {
        answered += 1
        guard let trimmed = neighbourhood?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
        let key = StreetNameFormatter.groupingKey(trimmed)
        counts[key, default: 0] += 1
        if display[key] == nil { display[key] = trimmed }
    }

    /// Smallest number of stops that makes 50%.
    private var required: Int { (totalStops + 1) / 2 }
    private var topCount: Int { counts.values.max() ?? 0 }

    /// The neighbourhood holding at least 50% of the stops, if exactly one does.
    public var winner: String? {
        guard totalStops > 0, topCount >= required else { return nil }
        let leaders = counts.filter { $0.value == topCount }
        guard leaders.count == 1, let key = leaders.first?.key else { return nil }
        return display[key]
    }

    /// True when more stops cannot change the result.
    public var isDecided: Bool {
        if totalStops == 0 || answered >= totalStops { return true }
        if topCount * 2 > totalStops { return true }                       // strict majority cannot be beaten
        return topCount + (totalStops - answered) < required              // can no longer reach 50%
    }
}

// MARK: - Result

public enum RouteNameRule: Sendable, Equatable {
    case singleRoad, twoRoads, neighbourhood, destination, routeNumber
}

public struct RouteNameSuggestion: Sendable, Equatable {
    /// Includes the " Express" suffix when `isExpress`.
    public let name: String
    public let rule: RouteNameRule
    public let isExpress: Bool
    public init(name: String, rule: RouteNameRule, isExpress: Bool) {
        self.name = name; self.rule = rule; self.isExpress = isExpress
    }
}

// MARK: - Rules

public enum RouteNamer {
    /// Strictly more than this share of the named length is needed for the road rules.
    public static let roadShare = 0.8
    /// Road rules are skipped if less of the route than this has a named road (roundabouts, ramps, gaps).
    public static let minimumNamedShare = 0.5
    /// A highway must carry strictly more than this share of the route for "Express".
    public static let expressShare = 0.5
    public static let expressSuffix = " Express"
    /// Between two road names. An em dash, with a space on each side.
    public static let roadDelimiter = " — "

    /// Measures how far each named road is followed by the route. The route is sampled every 50 m and each
    /// sample goes to the nearest road within 20 m that runs within 30 degrees of the route's direction.
    /// Roads are grouped by name without the road type, so "King Street East" and "King St W" are one road.
    /// Distance is summed per name; the route does not have to stay on one road without leaving it.
    public static func roadCoverage(geometry: RouteGeometry, roads: [NamedRoad], sampleSpacing: Double = 50,
                                    matchDistance: Double = 20, maxBearingDifference: Double = 30) -> RoadCoverage {
        let total = geometry.totalLength
        guard total > 0, sampleSpacing > 0 else {
            return RoadCoverage(stretches: [], namedMeters: 0, totalMeters: max(total, 0))
        }

        struct Prepared {
            let key: String, display: String
            let coordinates: [GeoCoordinate]
            let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
        }
        var prepared: [Prepared] = []
        for road in roads.sorted(by: { $0.id < $1.id }) {
            let base = StreetNameFormatter.baseName(road.name)
            guard !base.isEmpty, road.coordinates.count >= 2 else { continue }
            let lats = road.coordinates.map(\.latitude), lons = road.coordinates.map(\.longitude)
            prepared.append(Prepared(key: StreetNameFormatter.groupingKey(base), display: base,
                                     coordinates: road.coordinates,
                                     minLat: lats.min() ?? 0, maxLat: lats.max() ?? 0,
                                     minLon: lons.min() ?? 0, maxLon: lons.max() ?? 0))
        }

        var meters: [String: Double] = [:]
        var display: [String: String] = [:]
        var named = 0.0
        let sampleCount = Int((total / sampleSpacing).rounded(.up))
        for i in 0..<sampleCount {
            let start = Double(i) * sampleSpacing
            let weight = min(sampleSpacing, total - start)
            let distance = start + weight / 2
            let point = geometry.coordinate(atChainage: distance)
            let routeBearing = geometry.bearing(atChainage: distance)
            let latMargin = matchDistance / 110_540
            let lonMargin = matchDistance / max(111_320 * cos(point.latitude * .pi / 180), 1)

            var best: (distance: Double, index: Int)?
            for (index, road) in prepared.enumerated() {
                guard point.latitude >= road.minLat - latMargin, point.latitude <= road.maxLat + latMargin,
                      point.longitude >= road.minLon - lonMargin, point.longitude <= road.maxLon + lonMargin,
                      let near = nearestSegment(to: point, in: road.coordinates),
                      near.distance <= matchDistance else { continue }
                let raw = abs(near.bearing - routeBearing).truncatingRemainder(dividingBy: 360)
                let difference = min(raw, 360 - raw)
                guard min(difference, abs(180 - difference)) <= maxBearingDifference else { continue }
                if best == nil || near.distance < best!.distance { best = (near.distance, index) }
            }
            if let best {
                let road = prepared[best.index]
                meters[road.key, default: 0] += weight
                if display[road.key] == nil { display[road.key] = road.display }
                named += weight
            }
        }

        let stretches = meters
            .map { RoadStretch(name: display[$0.key] ?? $0.key, meters: $0.value) }
            .sorted { $0.meters != $1.meters ? $0.meters > $1.meters : $0.name < $1.name }
        return RoadCoverage(stretches: stretches, namedMeters: named, totalMeters: total)
    }

    /// Rules 1 and 2. Returns nil when neither applies.
    public static func roadName(from coverage: RoadCoverage) -> (name: String, rule: RouteNameRule)? {
        guard coverage.totalMeters > 0,
              coverage.namedMeters >= minimumNamedShare * coverage.totalMeters,
              let first = coverage.stretches.first else { return nil }
        if first.meters > roadShare * coverage.namedMeters { return (first.name, .singleRoad) }
        if coverage.stretches.count >= 2 {
            let second = coverage.stretches[1]
            if first.meters + second.meters > roadShare * coverage.namedMeters {
                return (first.name + roadDelimiter + second.name, .twoRoads)
            }
        }
        return nil
    }

    /// Applies the order of rules and the Express suffix.
    /// - Parameters:
    ///   - road: result of `roadName(from:)`.
    ///   - neighbourhood: `NeighbourhoodTally.winner`; pass nil if not checked.
    ///   - destinationName: the destination stop's assigned name; nil or blank if it has none.
    ///   - routeNumber: used as "Route N" when the destination has no name.
    ///   - highwayFraction: share of the route on a highway (`StopPlacementService.highwayFraction`).
    public static func finalize(road: (name: String, rule: RouteNameRule)?, neighbourhood: String?,
                                destinationName: String?, routeNumber: String,
                                highwayFraction: Double) -> RouteNameSuggestion {
        var name: String
        var rule: RouteNameRule
        if let road {
            name = road.name; rule = road.rule
        } else if let neighbourhood = clean(neighbourhood) {
            name = neighbourhood; rule = .neighbourhood
        } else if let destination = clean(destinationName) {
            name = "to \(destination)"; rule = .destination
        } else if let number = clean(routeNumber) {
            name = number.lowercased().hasPrefix("route") ? number : "Route \(number)"
            rule = .routeNumber
        } else {
            name = "Untitled Route"; rule = .routeNumber
        }
        let express = highwayFraction > expressShare
        if express { name += expressSuffix }
        return RouteNameSuggestion(name: name, rule: rule, isExpress: express)
    }

    // MARK: Helpers

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Nearest segment of a polyline to `point`: its distance in metres and its bearing in degrees (0 = north).
    private static func nearestSegment(to point: GeoCoordinate, in coordinates: [GeoCoordinate])
        -> (distance: Double, bearing: Double)? {
        guard coordinates.count >= 2 else { return nil }
        let kx = 111_320 * cos(point.latitude * .pi / 180), ky = 110_540.0
        var best: (distance: Double, bearing: Double)?
        for (a, b) in zip(coordinates, coordinates.dropFirst()) {
            let ax = (a.longitude - point.longitude) * kx, ay = (a.latitude - point.latitude) * ky
            let bx = (b.longitude - point.longitude) * kx, by = (b.latitude - point.latitude) * ky
            let dx = bx - ax, dy = by - ay
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(-(ax * dx + ay * dy) / lengthSquared, 0), 1) : 0
            let distance = hypot(ax + t * dx, ay + t * dy)
            if best == nil || distance < best!.distance {
                var bearing = atan2(dx, dy) * 180 / .pi
                if bearing < 0 { bearing += 360 }
                best = (distance, bearing)
            }
        }
        return best
    }
}
