import Foundation

/// Angle between two compass bearings, 0...180 (direction-sensitive).
func directedAngleDifference(_ a: Double, _ b: Double) -> Double {
    abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
}

public struct RouteMatch: Sendable, Equatable {
    public enum Confidence: String, Sendable, Equatable {
        case high, medium, low
    }

    /// Filtered position along the route, meters.
    public let chainage: Double
    /// Monotonic (never decreases): use this for arrival and announcement logic.
    public let progress: Double
    /// Smoothed speed along the route, m/s (negative when moving backwards).
    public let alongSpeed: Double
    /// Perpendicular offset from the route, positive = right of the direction of travel.
    public let lateralOffset: Double
    public let distanceToRoute: Double
    public let segmentBearing: Double
    /// Angle between the fix's course and the route direction, 0...180; nil when course is unusable.
    public let headingDelta: Double?
    public let snapped: GeoCoordinate
    public let confidence: Confidence
    /// True after several consecutive fixes show movement against the route direction.
    public let isReversing: Bool
    /// True when the matcher had to search the whole route because the windowed search found nothing.
    public let wasReacquired: Bool
    public let timestamp: Date
}

/// Matches successive fixes to the route polyline.
///
/// 1. Candidate projections are searched in a window around the previous progress (so loops and
///    overlapping route sections cannot be confused).
/// 2. Candidates are scored on distance, heading agreement and consistency with predicted progress.
/// 3. The winner feeds a Kalman filter, giving a smooth chainage and along-route speed.
public struct RouteMatcher: Sendable {
    public struct Configuration: Sendable {
        /// How far chainage may move backwards (jitter) before it counts as reversing.
        public var backwardTolerance = 25.0
        /// Course is only trusted above this speed (m/s).
        public var minSpeedForHeading = 2.0
        /// Search radius around the fix for candidate projections (at least 3x the reported accuracy).
        public var maxCandidateDistance = 150.0
        public var minAheadWindow = 200.0
        /// Consecutive "moving backwards" fixes before `isReversing` is set.
        public var reversingFixCount = 4

        public init() {}
    }

    public private(set) var geometry: RouteGeometry
    private let configuration: Configuration
    private var filter: ProgressFilter?
    private var progress = 0.0
    private var reverseCount = 0

    public init(geometry: RouteGeometry, configuration: Configuration = Configuration()) {
        self.geometry = geometry
        self.configuration = configuration
    }

    public mutating func reset(geometry: RouteGeometry) {
        self.geometry = geometry
        filter = nil
        progress = 0
        reverseCount = 0
    }

    /// Returns nil only if the route is degenerate. A fix far from the route still returns a (low confidence) match.
    public mutating func update(_ fix: LocationFix) -> RouteMatch? {
        guard geometry.vertices.count >= 2 else { return nil }
        let accuracy = max(fix.horizontalAccuracy, 5)
        let course: Double? = (fix.speed ?? 0) >= configuration.minSpeedForHeading ? fix.course : nil

        // 1. Predict and build the search window.
        var anchor: Double?
        var predicted: Double?
        var predictedSigma = 30.0
        var window: ClosedRange<Double>?
        if var current = filter {
            let before = current.position
            let dt = max(fix.timestamp.timeIntervalSince(current.time), 0)
            current.predict(to: fix.timestamp)
            filter = current
            anchor = before
            predicted = current.position
            let v = max(abs(current.speed), fix.speed ?? 0)
            predictedSigma = max(30, 0.3 * v * dt + accuracy)
            let ahead = max(configuration.minAheadWindow, v * dt * 1.5 + 100) + 2 * accuracy
            let behind = configuration.backwardTolerance + v * dt * 0.5 + 2 * accuracy
            let lower = max(min(before, current.position) - behind, 0)
            let upper = min(max(before, current.position) + ahead, geometry.totalLength)
            if lower <= upper { window = lower...upper }
        }

        // 2. Candidates.
        let radius = max(configuration.maxCandidateDistance, 3 * accuracy)
        var candidates = geometry.candidates(near: fix.coordinate, maxDistance: radius, window: window)
        var reacquired = false
        if candidates.isEmpty, window != nil {
            candidates = geometry.candidates(near: fix.coordinate, maxDistance: radius, window: nil)
            reacquired = !candidates.isEmpty
        }
        var farFromRoute = false
        if candidates.isEmpty {
            guard let nearest = geometry.project(fix.coordinate) else { return nil }
            candidates = [nearest]
            farFromRoute = true
        }

        // 3. Score.
        let tolerance = configuration.backwardTolerance
        func cost(_ c: RouteGeometry.Projection) -> Double {
            var total = pow(c.distance / accuracy, 2)
            if let course {
                let sigma = max(fix.courseAccuracy ?? 20, 15)
                total += min(pow(directedAngleDifference(course, c.segmentBearing) / sigma, 2), 16)
            }
            if let predicted, let anchor {
                total += min(pow((c.chainage - predicted) / predictedSigma, 2), 25)
                if c.chainage < anchor - tolerance - 2 * accuracy { total += 50 }
            }
            return total
        }
        let scored = candidates.map { (candidate: $0, cost: cost($0)) }
        guard let best = scored.min(by: {
            $0.cost < $1.cost || ($0.cost == $1.cost && $0.candidate.chainage < $1.candidate.chainage)
        })?.candidate else { return nil }

        // 4. Filter.
        let stationary = (fix.speed ?? 1) < 0.5
        let positionVariance = accuracy * accuracy * (stationary ? 4 : 1)
        let speedMeasurement = alongSpeed(of: fix, course: course, bearing: best.segmentBearing)
        if filter == nil || reacquired {
            filter = ProgressFilter(position: best.chainage, speed: speedMeasurement ?? 0,
                                    positionVariance: positionVariance, time: fix.timestamp)
        } else if var current = filter {
            current.update(position: best.chainage, variance: positionVariance)
            if let v = speedMeasurement {
                current.update(speed: v, variance: pow(max(fix.speedAccuracy ?? 1.5, 0.5), 2))
            }
            filter = current
        }
        guard let state = filter else { return nil }

        let chainage = min(max(state.position, 0), geometry.totalLength)
        progress = max(progress, chainage)
        let behind = progress - chainage > configuration.backwardTolerance
        reverseCount = (behind || state.speed < -1.5) ? reverseCount + 1 : 0

        // 5. Confidence.
        let headingDelta = course.map { directedAngleDifference($0, best.segmentBearing) }
        var confidence = RouteMatch.Confidence.high
        if best.distance > max(15, 1.5 * accuracy) { confidence = .medium }
        if reacquired || fix.horizontalAccuracy > 35 || (headingDelta ?? 0) > 45 { confidence = lowerConfidence(confidence, .medium) }
        if farFromRoute || best.distance > max(30, 3 * accuracy) || (headingDelta ?? 0) > 90 { confidence = .low }

        return RouteMatch(
            chainage: chainage,
            progress: progress,
            alongSpeed: state.speed,
            lateralOffset: best.lateralOffset,
            distanceToRoute: best.distance,
            segmentBearing: best.segmentBearing,
            headingDelta: headingDelta,
            snapped: best.snapped,
            confidence: confidence,
            isReversing: reverseCount >= configuration.reversingFixCount,
            wasReacquired: reacquired,
            timestamp: fix.timestamp
        )
    }

    private func alongSpeed(of fix: LocationFix, course: Double?, bearing: Double) -> Double? {
        guard let speed = fix.speed, speed >= 0 else { return nil }
        guard let course else { return speed }
        return speed * cos(directedAngleDifference(course, bearing) * .pi / 180)
    }
}

private func lowerConfidence(_ a: RouteMatch.Confidence, _ b: RouteMatch.Confidence) -> RouteMatch.Confidence {
    func rank(_ c: RouteMatch.Confidence) -> Int {
        switch c {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }
    return rank(a) <= rank(b) ? a : b
}
