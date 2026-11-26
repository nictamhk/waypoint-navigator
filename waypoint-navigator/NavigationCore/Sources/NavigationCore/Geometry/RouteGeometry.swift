import Foundation

public enum GeometryError: Error, Equatable {
    case emptyLeg(index: Int)
    case degenerateRoute
}

/// The merged polyline of all legs, indexed by *chainage* (meters along the route).
///
/// Every later phase (matching, progress, arrival, ETA) works in chainage:
/// remaining distance to a stop is simply `stopChainage - currentChainage`.
public struct RouteGeometry: Sendable, Codable, Equatable {
    public let vertices: [GeoCoordinate]
    /// For each leg, the index of its last vertex in `vertices`.
    public let legEndVertexIndices: [Int]
    /// Meters from the route start at each vertex. `cumulativeDistance[0] == 0`.
    public let cumulativeDistance: [Double]

    public var totalLength: Double { cumulativeDistance.last ?? 0 }
    public var legCount: Int { legEndVertexIndices.count }
    /// Chainage at the end of each leg (= chainage of waypoint i+1).
    public var legEndChainages: [Double] { legEndVertexIndices.map { cumulativeDistance[$0] } }

    public struct Projection: Sendable, Equatable {
        /// Distance along the route of the projected point.
        public let chainage: Double
        /// Perpendicular offset from the segment's line, meters. Positive = right of travel direction.
        public let lateralOffset: Double
        /// True distance from the query point to the route (>= |lateralOffset| near segment ends).
        public let distance: Double
        public let segmentIndex: Int
        /// Direction of travel at that segment, degrees clockwise from north.
        public let segmentBearing: Double
        public let snapped: GeoCoordinate
    }

    public init(vertices: [GeoCoordinate], legEndVertexIndices: [Int]) {
        self.vertices = vertices
        self.legEndVertexIndices = legEndVertexIndices
        var cumulative = [Double](repeating: 0, count: vertices.count)
        if vertices.count > 1 {
            for i in 1..<vertices.count {
                cumulative[i] = cumulative[i - 1] + vertices[i - 1].distance(to: vertices[i])
            }
        }
        self.cumulativeDistance = cumulative
    }

    /// Merges per-leg polylines into one route.
    /// - Drops a leg's first vertex if it coincides (within `jointTolerance`) with the previous leg's end.
    /// - Drops consecutive vertices closer than `minVertexSpacing`.
    public init(legs: [[GeoCoordinate]], jointTolerance: Double = 5, minVertexSpacing: Double = 0.01) throws {
        var merged: [GeoCoordinate] = []
        var ends: [Int] = []
        for (legIndex, leg) in legs.enumerated() {
            guard leg.count >= 2 else { throw GeometryError.emptyLeg(index: legIndex) }
            for (vertexIndex, coordinate) in leg.enumerated() {
                if let last = merged.last {
                    let gap = last.distance(to: coordinate)
                    let limit = vertexIndex == 0 ? jointTolerance : minVertexSpacing
                    if gap <= limit { continue }
                }
                merged.append(coordinate)
            }
            ends.append(merged.count - 1)
        }
        guard merged.count >= 2 else { throw GeometryError.degenerateRoute }
        self.init(vertices: merged, legEndVertexIndices: ends)
    }

    // MARK: Codable (cumulative distances are rebuilt on decode)

    private enum CodingKeys: String, CodingKey { case vertices, legEndVertexIndices }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(vertices: try container.decode([GeoCoordinate].self, forKey: .vertices),
                  legEndVertexIndices: try container.decode([Int].self, forKey: .legEndVertexIndices))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(vertices, forKey: .vertices)
        try container.encode(legEndVertexIndices, forKey: .legEndVertexIndices)
    }

    // MARK: Chainage -> geometry

    /// Index of the segment containing `chainage` (largest i with cumulative[i] <= chainage).
    func segmentIndex(containing chainage: Double) -> Int {
        var low = 0
        var high = max(vertices.count - 2, 0)
        while low < high {
            let mid = (low + high + 1) / 2
            if cumulativeDistance[mid] <= chainage { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func coordinate(atChainage chainage: Double) -> GeoCoordinate {
        guard vertices.count >= 2 else { return vertices.first ?? GeoCoordinate(latitude: 0, longitude: 0) }
        let s = min(max(chainage, 0), totalLength)
        let i = segmentIndex(containing: s)
        let length = cumulativeDistance[i + 1] - cumulativeDistance[i]
        let t = length > 0 ? (s - cumulativeDistance[i]) / length : 0
        let a = vertices[i], b = vertices[i + 1]
        return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                             longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    public func bearing(atChainage chainage: Double) -> Double {
        guard vertices.count >= 2 else { return 0 }
        let i = segmentIndex(containing: min(max(chainage, 0), totalLength))
        return vertices[i].bearing(to: vertices[i + 1])
    }

    // MARK: Point -> chainage

    /// Projects `point` onto the route.
    /// - Parameter window: optional chainage range. Only segments overlapping the window are searched,
    ///   which prevents jumping between passes of a loop or overlapping route. The returned chainage
    ///   may lie slightly outside the window (the first/last segment is searched in full).
    /// - Returns: the closest projection; on near-ties the lowest chainage wins. `nil` if the window is
    ///   entirely outside the route.
    public func project(_ point: GeoCoordinate, window: ClosedRange<Double>? = nil) -> Projection? {
        guard vertices.count >= 2 else { return nil }
        var first = 0
        var last = vertices.count - 2
        if let window {
            guard window.upperBound >= 0, window.lowerBound <= totalLength else { return nil }
            first = segmentIndex(containing: max(window.lowerBound, 0))
            last = segmentIndex(containing: min(window.upperBound, totalLength))
        }
        var best: Projection?
        for i in first...last {
            let candidate = projectOnSegment(point, segment: i)
            if let best, candidate.distance >= best.distance - 1e-6 { continue }
            best = candidate
        }
        return best
    }

    /// Local-minimum projections of `point` within `maxDistance` of the route: one candidate per "pass"
    /// of the route near the point. Used when the route overlaps itself and the caller must choose
    /// between passes using heading and progress. `window` behaves as in `project`.
    public func candidates(near point: GeoCoordinate, maxDistance: Double,
                           window: ClosedRange<Double>? = nil) -> [Projection] {
        guard vertices.count >= 2 else { return [] }
        var first = 0
        var last = vertices.count - 2
        if let window {
            guard window.upperBound >= 0, window.lowerBound <= totalLength else { return [] }
            first = segmentIndex(containing: max(window.lowerBound, 0))
            last = segmentIndex(containing: min(window.upperBound, totalLength))
        }
        var all: [Projection] = []
        for i in first...last { all.append(projectOnSegment(point, segment: i)) }
        var result: [Projection] = []
        for (k, candidate) in all.enumerated() {
            guard candidate.distance <= maxDistance else { continue }
            if k > 0, all[k - 1].distance < candidate.distance - 1e-6 { continue }
            if k + 1 < all.count, all[k + 1].distance < candidate.distance - 1e-6 { continue }
            if let previous = result.last, abs(previous.chainage - candidate.chainage) < 1.0 { continue }
            result.append(candidate)
        }
        return result
    }

    private func projectOnSegment(_ point: GeoCoordinate, segment i: Int) -> Projection {
        let a = vertices[i], b = vertices[i + 1]
        let frame = LocalFrame(origin: a)
        let (bx, by) = frame.local(b)
        let (px, py) = frame.local(point)
        let lengthSquared = bx * bx + by * by
        let length = lengthSquared.squareRoot()
        let t = lengthSquared > 0 ? min(max((px * bx + py * by) / lengthSquared, 0), 1) : 0
        let cx = bx * t, cy = by * t
        let lateral = length > 0 ? (px * by - py * bx) / length : 0   // positive = right of travel
        var bearing = atan2(bx, by) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return Projection(
            chainage: cumulativeDistance[i] + t * (cumulativeDistance[i + 1] - cumulativeDistance[i]),
            lateralOffset: lateral,
            distance: hypot(px - cx, py - cy),
            segmentIndex: i,
            segmentBearing: bearing,
            snapped: frame.coordinate(x: cx, y: cy)
        )
    }
}
