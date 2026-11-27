import Foundation

/// OSM feature classes understood by automatic stop placement.
public enum StopFeatureKind: Sendable, Equatable {
    case busStop
    case signalizedMajorIntersection
    case landmark
    case minorIntersection
    case highwayExit
}

public struct StopFeature: Sendable, Equatable {
    public let id: String
    public let coordinate: GeoCoordinate
    public let kind: StopFeatureKind
    public let name: String?
    public let ref: String?
    public let detail: String?

    public init(id: String, coordinate: GeoCoordinate, kind: StopFeatureKind,
                name: String? = nil, ref: String? = nil, detail: String? = nil) {
        self.id = id; self.coordinate = coordinate; self.kind = kind
        self.name = name; self.ref = ref; self.detail = detail
    }
}

/// An OSM highway way eligible for Express Mode detection.
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
}

public struct StopPlacementResult: Sendable, Equatable {
    public let stops: [PlacedStop]
    public let effectiveInterval: Double
}

public enum StopPlacementService {
    public static let maximumStops = 48
    private static let corridor = 50.0

    /// Generates stop placements. `interval` is the selected minimum interval in meters.
    public static func generate(geometry: RouteGeometry, interval: Double,
                                features: [StopFeature], highwayWays: [HighwayWay] = [],
                                expressMode: Bool = false) -> StopPlacementResult {
        let selected = max(interval, 1)
        let unique = Dictionary(features.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        var effective = max(selected, geometry.totalLength / Double(maximumStops - 1))
        var generated = run(geometry, effective, Array(unique), highwayWays, expressMode)
        // Highway exits are thinned first when an Express plan exceeds the cap.
        if generated.count + 2 > maximumStops, expressMode {
            var exitIndex = 0
            generated = generated.filter { stop in
                guard stop.isHighwayExit else { return true }
                defer { exitIndex += 1 }
                return exitIndex.isMultiple(of: 2)
            }
        }
        // Raising the interval guarantees the ordinary interval grid fits the cap.
        while generated.count + 2 > maximumStops {
            effective = max(effective * 1.25, geometry.totalLength / Double(maximumStops - 1))
            generated = run(geometry, effective, Array(unique), highwayWays, expressMode)
        }
        let origin = PlacedStop(chainage: 0, coordinate: geometry.coordinate(atChainage: 0), name: nil,
                                detail: nil, featureID: nil, isMandatory: true, isHighwayExit: false)
        let destination = PlacedStop(chainage: geometry.totalLength,
                                     coordinate: geometry.coordinate(atChainage: geometry.totalLength), name: nil,
                                     detail: nil, featureID: nil, isMandatory: true, isHighwayExit: false)
        if let last = generated.last, geometry.totalLength - last.chainage < effective { generated.removeLast() }
        return StopPlacementResult(stops: [origin] + generated + [destination], effectiveInterval: effective)
    }

    private static func run(_ geometry: RouteGeometry, _ interval: Double, _ features: [StopFeature],
                            _ ways: [HighwayWay], _ express: Bool) -> [PlacedStop] {
        let highways = express ? highwaySegments(geometry, ways) : []
        var output: [PlacedStop] = [], last = 0.0, cursor = interval
        while cursor < geometry.totalLength {
            if let segment = highways.first(where: { cursor >= $0.start && cursor <= $0.end }) {
                let exits = features.compactMap { feature -> (StopFeature, Double, GeoCoordinate)? in
                    guard feature.kind == .highwayExit,
                          let projection = geometry.project(feature.coordinate, window: segment.start...segment.end),
                          projection.distance <= corridor, projection.chainage >= last + 2_000 else { return nil }
                    return (feature, projection.chainage, projection.snapped)
                }.sorted { $0.1 < $1.1 }
                if let exit = exits.first(where: { $0.1 >= cursor }) {
                    let name = clean(exit.0.name) ?? clean(exit.0.ref).map { "Exit \($0)" }
                    if let name {
                        output.append(PlacedStop(chainage: exit.1, coordinate: exit.2, name: name,
                                                 detail: clean(exit.0.detail), featureID: exit.0.id,
                                                 isMandatory: false, isHighwayExit: true))
                        last = exit.1; cursor = last + 2_000; continue
                    }
                }
                cursor = max(last, segment.end - 0.5 * interval)
                cursor += interval
                continue
            }
            let end = min(cursor + interval, geometry.totalLength)
            let candidates = features.compactMap { feature -> (StopFeature, Double, GeoCoordinate)? in
                guard feature.kind != .highwayExit,
                      let projection = geometry.project(feature.coordinate, window: cursor...end),
                      projection.distance <= corridor, projection.chainage >= last + interval else { return nil }
                return (feature, projection.chainage, projection.snapped)
            }
            if let selected = candidates.sorted(by: {
                let a = priority($0.0.kind), b = priority($1.0.kind)
                return a == b ? abs($0.1 - end) < abs($1.1 - end) : a < b
            }).first {
                output.append(PlacedStop(chainage: selected.1, coordinate: selected.2,
                                         name: clean(selected.0.name), detail: clean(selected.0.detail),
                                         featureID: selected.0.id, isMandatory: false, isHighwayExit: false))
                last = selected.1; cursor = last + interval
            } else { cursor += interval }
        }
        return output
    }

    private struct Segment { let start: Double; let end: Double }
    private static func highwaySegments(_ geometry: RouteGeometry, _ ways: [HighwayWay]) -> [Segment] {
        let valid = ways.filter { ($0.highway == "motorway" || $0.highway == "trunk") && $0.expressway }
        var runs: [Segment] = [], start: Double?, previous: Double?
        var distance = 0.0
        while distance <= geometry.totalLength {
            let routeBearing = geometry.bearing(atChainage: distance)
            let sample = geometry.coordinate(atChainage: distance)
            let matched = valid.contains { way in
                guard let projection = polylineProjection(sample, way.coordinates) else { return false }
                return projection.distance <= 25 && bearingDifference(routeBearing, projection.bearing) <= 30
            }
            if matched { if start == nil { start = distance }; previous = distance }
            else { appendRun(&runs, start, previous); start = nil; previous = nil }
            distance += 50
        }
        appendRun(&runs, start, previous)
        return runs
    }
    private static func appendRun(_ runs: inout [Segment], _ start: Double?, _ end: Double?) {
        if let start, let end, end - start >= 1_000 { runs.append(Segment(start: start, end: end)) }
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
    private static func priority(_ kind: StopFeatureKind) -> Int {
        switch kind { case .busStop: 0; case .signalizedMajorIntersection: 1; case .landmark: 2; case .minorIntersection: 3; case .highwayExit: 4 }
    }
    private static func clean(_ text: String?) -> String? { text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    private static func bearingDifference(_ a: Double, _ b: Double) -> Double { let d = abs(a - b).truncatingRemainder(dividingBy: 360); return min(d, 360 - d) }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
