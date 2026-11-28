import Foundation

/// OSM feature classes understood by automatic stop placement.
public enum StopFeatureKind: Sendable, Equatable, Hashable {
    case busStop
    case trainMetroStation
    /// Major tier: a signalized junction, or a junction with a trunk/primary/secondary cross street.
    /// (The case name is kept so existing code and tests still compile.)
    case signalizedMajorIntersection
    case landmark
    /// Minor tier: a junction with a tertiary/unclassified/residential cross street.
    case minorIntersection
    case highwayExit
}

public struct StopFeature: Sendable, Equatable {
    public let id: String
    public let coordinate: GeoCoordinate
    public let kind: StopFeatureKind
    /// Default (untagged) name.
    public let name: String?
    /// Language code -> name. The key "default" holds the untagged `name`; others come from `name:xx` tags.
    public let names: [String: String]
    public let ref: String?
    public let detail: String?

    public init(id: String, coordinate: GeoCoordinate, kind: StopFeatureKind,
                name: String? = nil, ref: String? = nil, detail: String? = nil,
                names: [String: String] = [:]) {
        var all = names
        if let name, !name.isEmpty, all["default"] == nil { all["default"] = name }
        self.id = id; self.coordinate = coordinate; self.kind = kind
        self.name = name ?? all["default"]
        self.names = all
        self.ref = ref; self.detail = detail
    }
}

/// An OSM highway way eligible for highway-segment detection.
public struct HighwayWay: Sendable, Equatable {
    public let id: String
    public let coordinates: [GeoCoordinate]
    public let highway: String
    public let expressway: Bool

    public init(id: String, coordinates: [GeoCoordinate], highway: String, expressway: Bool) {
        self.id = id; self.coordinates = coordinates; self.highway = highway; self.expressway = expressway
    }
}

public struct PlacedStop: Sendable, Equatable {
    public let chainage: Double
    /// Always snapped to the route polyline.
    public let coordinate: GeoCoordinate
    public let name: String?
    public let detail: String?
    public let featureID: String?
    public let isMandatory: Bool
    public let isHighwayExit: Bool
    /// Language code -> name (see `StopFeature.names`). Empty for origin, destination and address stops.
    public let names: [String: String]
    /// Feature class that produced the stop; nil for origin, destination and address stops.
    public let kind: StopFeatureKind?
    /// True for address-tier stops, which are only generated when `addressFallback` is on (online place data
    /// unavailable). The caller should reverse-geocode `coordinate` to name it, and may drop it.
    public let needsAddress: Bool

    public init(chainage: Double, coordinate: GeoCoordinate, name: String?, detail: String?,
                featureID: String?, isMandatory: Bool, isHighwayExit: Bool,
                names: [String: String] = [:], kind: StopFeatureKind? = nil, needsAddress: Bool = false) {
        self.chainage = chainage; self.coordinate = coordinate; self.name = name; self.detail = detail
        self.featureID = featureID; self.isMandatory = isMandatory; self.isHighwayExit = isHighwayExit
        self.names = names; self.kind = kind; self.needsAddress = needsAddress
    }
}

public struct StopPlacementResult: Sendable, Equatable {
    public let stops: [PlacedStop]
    /// The minimum spacing actually used (metres). Larger than `requestedInterval` when the stop cap forced it up.
    public let effectiveInterval: Double
    public let requestedInterval: Double

    public var wasAdjusted: Bool { effectiveInterval > requestedInterval * 1.01 }

    public init(stops: [PlacedStop], effectiveInterval: Double, requestedInterval: Double? = nil) {
        self.stops = stops
        self.effectiveInterval = effectiveInterval
        self.requestedInterval = requestedInterval ?? effectiveInterval
    }
}

public enum StopPlacementService {
    /// Hard limit on the total number of stops, including origin and destination.
    public static let maximumStops = 48
    /// The generator aims for this total (origin and destination included), leaving one spare slot.
    public static let targetStops = maximumStops

    // MARK: Tunable constants

    /// Search order inside each window: the first tier that has a valid candidate wins.
    private static let tierOrder: [StopFeatureKind] = [
        .busStop, .trainMetroStation, .signalizedMajorIntersection, .landmark, .minorIntersection
    ]
    private static let highwayExitSpacing = 2_000.0
    private static let highwayExitSlack = 100.0          // exits just past the end of a detected segment still count
    private static let highwayMinimumLength = 1_000.0
    private static let intervalGrowth = 1.05
    private static let maximumAdaptationSteps = 80

    /// Generates stop placements. `interval` is the selected MINIMUM spacing in metres.
    ///
    /// - Stops are only placed at real features: bus stop, major intersection, minor intersection, landmark.
    ///   Each stop is at least `interval` after the previous stop and at least `interval` before the destination.
    /// - The search starts at (previous stop + interval) and looks through consecutive windows, each `interval`
    ///   long. In a window the first tier with a candidate wins, in the order above; within a tier the candidate
    ///   closest to the start of the window is taken (bus stops on the right-hand side first).
    /// - If a window holds no candidate the search simply moves on to the next window, so a rural road can go a
    ///   long way without stops. Nothing is invented to fill the gap.
    /// - On a detected highway stretch the interval does not drive placement: stops go only at named exits at
    ///   least max(2 km, interval) apart.
    /// - If the result would exceed `targetStops`, the minimum grows by 5% steps and everything is recalculated.
    /// - `addressFallback` is for when online place data could not be loaded at all: instead of moving on, a
    ///   stop is placed exactly `interval` after the previous one as an address stop (`needsAddress`), which the
    ///   caller reverse-geocodes. Leave it false otherwise.
    /// - `expressMode` is kept for source compatibility. The highway rule applies whenever the route really runs
    ///   on a highway, because MapKit's highway preference is only a preference.
    public static func generate(geometry: RouteGeometry, interval: Double,
                                features: [StopFeature], highwayWays: [HighwayWay] = [],
                                expressMode: Bool = false, addressFallback: Bool = false) -> StopPlacementResult {
        let requested = max(interval, 1)
        let highways = expressMode ? highwaySegments(geometry, highwayWays) : []
        let pool = makePool(geometry: geometry, features: features, highways: highways)

        // A uniform spacing of total / 47 guarantees room for both mandatory endpoints
        // and at most 46 intermediate stops, even before feature availability is known.
        var effective = max(requested, geometry.totalLength / Double(maximumStops - 1))
        var generated = run(geometry: geometry, interval: effective, pool: pool, highways: highways,
                            addressFallback: addressFallback)
        var steps = 0
        while generated.count + 2 > maximumStops, steps < maximumAdaptationSteps {
            effective *= intervalGrowth
            generated = run(geometry: geometry, interval: effective, pool: pool, highways: highways,
                            addressFallback: addressFallback)
            steps += 1
        }

        let origin = PlacedStop(chainage: 0, coordinate: geometry.coordinate(atChainage: 0), name: nil,
                                detail: nil, featureID: nil, isMandatory: true, isHighwayExit: false)
        let destination = PlacedStop(chainage: geometry.totalLength,
                                     coordinate: geometry.coordinate(atChainage: geometry.totalLength), name: nil,
                                     detail: nil, featureID: nil, isMandatory: true, isHighwayExit: false)
        return StopPlacementResult(stops: [origin] + generated + [destination],
                                   effectiveInterval: effective, requestedInterval: requested)
    }

    /// Fraction of route chainage covered by Express Mode highway segments.
    public static func highwayFraction(geometry: RouteGeometry, highwayWays: [HighwayWay]) -> Double {
        guard geometry.totalLength > 0 else { return 0 }
        let covered = highwaySegments(geometry, highwayWays).reduce(0.0) { $0 + ($1.end - $1.start) }
        return min(covered / geometry.totalLength, 1)
    }

    // MARK: - Candidate pool

    private struct Candidate {
        let feature: StopFeature
        let chainage: Double
        let snapped: GeoCoordinate
        /// Metres from the route; positive = right of the direction of travel (right-hand traffic).
        let lateral: Double
    }

    private struct Pool {
        var urban: [StopFeatureKind: [Candidate]] = [:]   // each list sorted by chainage
        var exits: [Candidate] = []                       // sorted by chainage
    }

    private static func corridor(for kind: StopFeatureKind) -> Double {
        switch kind {
        case .busStop, .trainMetroStation: return 60
        case .signalizedMajorIntersection, .minorIntersection: return 25
        case .landmark: return 150
        case .highwayExit: return 40
        }
    }

    /// Projects every feature onto the route once. Sorting makes the result independent of input order.
    private static func makePool(geometry: RouteGeometry, features: [StopFeature], highways: [Segment]) -> Pool {
        let total = geometry.totalLength
        guard total > 0 else { return Pool() }
        var seen = Set<String>()
        let unique = features.sorted { $0.id < $1.id }.filter { seen.insert($0.id).inserted }
        var pool = Pool()
        for feature in unique {
            guard let projection = geometry.project(feature.coordinate, window: 0...total),
                  projection.distance <= corridor(for: feature.kind) else { continue }
            let bearing = geometry.bearing(atChainage: projection.chainage)
            let candidate = Candidate(
                feature: feature, chainage: projection.chainage, snapped: projection.snapped,
                lateral: lateralOffset(of: feature.coordinate, from: projection.snapped, bearing: bearing))
            if feature.kind == .highwayExit {
                if exitLabels(feature) != nil { pool.exits.append(candidate) }
                continue
            }
            // Urban tiers are ignored on highways; the exit rule applies there.
            if highways.contains(where: { projection.chainage >= $0.start - highwayExitSlack
                                          && projection.chainage <= $0.end + highwayExitSlack }) { continue }
            guard usableName(feature) != nil else { continue }
            pool.urban[feature.kind, default: []].append(candidate)
        }
        let ordered: (Candidate, Candidate) -> Bool = {
            $0.chainage == $1.chainage ? $0.feature.id < $1.feature.id : $0.chainage < $1.chainage
        }
        pool.exits.sort(by: ordered)
        for kind in pool.urban.keys { pool.urban[kind]?.sort(by: ordered) }
        return pool
    }

    /// Signed distance (metres) of `point` to the right of a route heading `bearing` (degrees) at `snapped`.
    private static func lateralOffset(of point: GeoCoordinate, from snapped: GeoCoordinate, bearing: Double) -> Double {
        let east = (point.longitude - snapped.longitude) * cos(snapped.latitude * .pi / 180) * 111_320
        let north = (point.latitude - snapped.latitude) * 110_540
        let theta = bearing * .pi / 180
        return east * cos(theta) - north * sin(theta)
    }

    // MARK: - Main loop

    private static func run(geometry: RouteGeometry, interval: Double, pool: Pool, highways: [Segment],
                            addressFallback: Bool) -> [PlacedStop] {
        let total = geometry.totalLength
        let exitSpacing = max(highwayExitSpacing, interval)
        let latest = total - interval        // a stop may not be closer than `interval` to the destination
        var output: [PlacedStop] = []
        var usedNames = Set<String>()
        var cursor = 0.0                     // chainage of the previous stop (the origin counts as 0)
        var windowStart = interval           // earliest chainage the next stop may have

        while windowStart <= latest {
            // Highway rule: named exits at least `exitSpacing` apart; the interval does not apply.
            if let segment = highways.first(where: { windowStart >= $0.start && windowStart <= $0.end }) {
                let earliest = max(segment.start, cursor + exitSpacing)
                let exit = pool.exits.first { candidate in
                    guard candidate.chainage >= earliest,
                          candidate.chainage <= segment.end + highwayExitSlack,
                          candidate.chainage <= latest,
                          let label = exitLabels(candidate.feature),
                          !usedNames.contains(label.name.lowercased()) else { return false }
                    return true
                }
                if let exit, let label = exitLabels(exit.feature) {
                    output.append(PlacedStop(
                        chainage: exit.chainage, coordinate: exit.snapped, name: label.name, detail: label.detail,
                        featureID: exit.feature.id, isMandatory: false, isHighwayExit: true,
                        names: exit.feature.names, kind: .highwayExit))
                    usedNames.insert(label.name.lowercased())
                    cursor = exit.chainage
                    windowStart = cursor + interval
                } else {
                    // No usable exit left in this segment: carry on after it.
                    windowStart = max(cursor, segment.end - 0.5 * interval) + interval
                }
                continue
            }

            // Urban rule: one window of length `interval`, not running into the next highway segment.
            var windowEnd = windowStart + interval
            if let next = highways.first(where: { $0.start > windowStart }), next.start < windowEnd {
                windowEnd = next.start
            }
            windowEnd = min(windowEnd, latest)

            var chosen: Candidate?
            for kind in tierOrder {
                guard let list = pool.urban[kind] else { continue }
                var inWindow: [Candidate] = []
                var index = firstIndex(in: list, atOrAfter: windowStart)
                while index < list.count, list[index].chainage <= windowEnd {
                    let candidate = list[index]
                    index += 1
                    if let name = usableName(candidate.feature), !usedNames.contains(name.lowercased()),
                       output.allSatisfy({ candidate.snapped.distance(to: $0.coordinate) >= interval }),
                       candidate.snapped.distance(to: geometry.coordinate(atChainage: total)) >= interval {
                        inWindow.append(candidate)
                    }
                }
                if kind == .busStop {
                    // Right-hand traffic: prefer stops on the right of the direction of travel.
                    let rightSide = inWindow.filter { $0.lateral >= -3 }
                    if !rightSide.isEmpty { inWindow = rightSide }
                }
                // Closest to the start of the window keeps spacing near the minimum.
                if let best = inWindow.min(by: { isCloser($0, than: $1, to: windowStart) }) {
                    chosen = best
                    break
                }
            }

            if let chosen, let name = usableName(chosen.feature) {
                output.append(PlacedStop(
                    chainage: chosen.chainage, coordinate: chosen.snapped, name: name,
                    detail: clean(chosen.feature.detail), featureID: chosen.feature.id,
                    isMandatory: false, isHighwayExit: false,
                    names: chosen.feature.names, kind: chosen.feature.kind))
                usedNames.insert(name.lowercased())
                cursor = chosen.chainage
                windowStart = cursor + interval
            } else if addressFallback {
                output.append(PlacedStop(
                    chainage: windowStart, coordinate: geometry.coordinate(atChainage: windowStart), name: nil,
                    detail: nil, featureID: nil, isMandatory: false, isHighwayExit: false, needsAddress: true))
                cursor = windowStart
                windowStart = cursor + interval
            } else {
                // Nothing noteworthy here: slide on to the next window (always moves forward).
                windowStart = windowEnd > windowStart ? windowEnd : windowStart + 1
            }
        }
        return output
    }

    private static func isCloser(_ a: Candidate, than b: Candidate, to target: Double) -> Bool {
        let da = abs(a.chainage - target), db = abs(b.chainage - target)
        if da != db { return da < db }
        let la = abs(a.lateral), lb = abs(b.lateral)
        if la != lb { return la < lb }
        return a.feature.id < b.feature.id
    }

    /// Binary search: first index whose chainage is >= `chainage`.
    private static func firstIndex(in list: [Candidate], atOrAfter chainage: Double) -> Int {
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].chainage < chainage { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: - Names

    private static func usableName(_ feature: StopFeature) -> String? {
        clean(feature.name)
    }

    /// Highway destination guidance is the stop name when present; the junction name and ref are fallbacks.
    private static func exitLabels(_ feature: StopFeature) -> (name: String, detail: String?)? {
        let exitName = clean(feature.name)
        let ref = clean(feature.ref).map { "Exit \($0)" }
        let destinations = clean(feature.detail)
        guard let name = destinations ?? exitName ?? ref else { return nil }
        var extras: [String] = []
        if let exitName, exitName != name { extras.append(exitName) }
        if let ref, ref != name { extras.append(ref) }
        return (name, extras.isEmpty ? nil : extras.joined(separator: " · "))
    }

    private static func clean(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Highway segments

    private struct Segment { let start: Double; let end: Double }

    /// A highway is a `motorway`, or a `trunk` tagged `expressway=yes` (plain motorways are not tagged
    /// `expressway`, so requiring the tag on both would miss every motorway).
    /// The route is sampled every 50 m; a sample is on a highway if a valid way lies within 25 m and runs
    /// within 30 degrees of the route's bearing. Gaps shorter than 150 m are bridged; runs shorter than
    /// 500 m are dropped.
    private static func highwaySegments(_ geometry: RouteGeometry, _ ways: [HighwayWay]) -> [Segment] {
        let valid = ways.filter { $0.highway == "motorway" || ($0.highway == "trunk" && $0.expressway) }
        guard !valid.isEmpty, geometry.totalLength > 0 else { return [] }
        var runs: [Segment] = []
        var start: Double?
        var lastMatch = 0.0
        var distance = 0.0
        while distance <= geometry.totalLength {
            let routeBearing = geometry.bearing(atChainage: distance)
            let sample = geometry.coordinate(atChainage: distance)
            let matched = valid.contains { way in
                guard let projection = polylineProjection(sample, way.coordinates) else { return false }
                let difference = bearingDifference(routeBearing, projection.bearing)
                return projection.distance <= 25 && min(difference, abs(180 - difference)) <= 30
            }
            if matched {
                if start == nil { start = distance }
                lastMatch = distance
            } else if let openStart = start, distance - lastMatch > 150 {
                appendRun(&runs, openStart, lastMatch)
                start = nil
            }
            distance += 50
        }
        if let openStart = start { appendRun(&runs, openStart, lastMatch) }
        return runs
    }

    private static func appendRun(_ runs: inout [Segment], _ start: Double, _ end: Double) {
        if end - start >= highwayMinimumLength { runs.append(Segment(start: start, end: end)) }
    }

    private static func polylineProjection(_ point: GeoCoordinate, _ vertices: [GeoCoordinate]) -> (distance: Double, bearing: Double)? {
        guard vertices.count > 1 else { return nil }
        var best: (Double, Double)?
        for pair in zip(vertices, vertices.dropFirst()) {
            let a = pair.0, b = pair.1, frame = LocalFrame(origin: a)
            let (bx, by) = frame.local(b), (px, py) = frame.local(point)
            let d = bx * bx + by * by
            let t = d > 0 ? min(max((px * bx + py * by) / d, 0), 1) : 0
            let distance = hypot(px - bx * t, py - by * t)
            if best == nil || distance < best!.0 { best = (distance, a.bearing(to: b)) }
        }
        return best.map { ($0.0, $0.1) }
    }

    private static func bearingDifference(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

/// Helpers for turning placed stops into display titles that are unique within one route.
public enum StopNaming {
    /// "Name · detail", or just the name.
    public static func title(name: String?, detail: String?) -> String? {
        let n = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !n.isEmpty { return d.isEmpty ? n : "\(n) · \(d)" }
        return d.isEmpty ? nil : d
    }

    /// Makes titles unique, ignoring case. The first use of a title is left alone; later duplicates get a
    /// kilometre marker, for example "Main St (km 12.4)", and as a last resort a counter.
    public static func makeUnique(_ items: [(title: String, chainage: Double)]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            var title = item.title
            if seen.contains(title.lowercased()) {
                title = "\(item.title) (km \(String(format: "%.1f", item.chainage / 1000)))"
                var counter = 2
                while seen.contains(title.lowercased()) {
                    title = "\(item.title) (km \(String(format: "%.1f", item.chainage / 1000)), \(counter))"
                    counter += 1
                }
            }
            seen.insert(title.lowercased())
            result.append(title)
        }
        return result
    }
}
