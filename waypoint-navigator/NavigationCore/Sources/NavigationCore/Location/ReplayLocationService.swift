import Foundation

/// Deterministic SplitMix64 generator so injected noise is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12)
        let u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Plays back a recorded or synthetic track as a stream of fixes, with optional fault injection.
public struct ReplayLocationService: LocationServicing {
    public struct Jump: Sendable {
        public var at: TimeInterval          // seconds from track start
        public var duration: TimeInterval
        public var eastMeters: Double
        public var northMeters: Double

        public init(at: TimeInterval, duration: TimeInterval, eastMeters: Double, northMeters: Double) {
            self.at = at; self.duration = duration
            self.eastMeters = eastMeters; self.northMeters = northMeters
        }
    }

    public struct Faults: Sendable {
        /// Per-axis Gaussian position noise (standard deviation, meters).
        public var jitterSigma: Double = 0
        /// Elapsed-time ranges (seconds from track start) during which no fixes are delivered.
        public var dropouts: [ClosedRange<TimeInterval>] = []
        /// Temporary position offsets simulating multipath/urban-canyon jumps.
        public var jumps: [Jump] = []
        public var seed: UInt64 = 1

        public init() {}
    }

    public let track: [LocationFix]
    /// 1 = real time, 10 = ten times faster, `.infinity` = no waiting (tests).
    public let speedMultiplier: Double
    public let faults: Faults

    public init(track: [LocationFix], speedMultiplier: Double = 1, faults: Faults = Faults()) {
        self.track = track
        self.speedMultiplier = speedMultiplier
        self.faults = faults
    }

    private func prepared() -> [(elapsed: TimeInterval, fix: LocationFix)] {
        guard let start = track.first?.timestamp else { return [] }
        var generator = SeededGenerator(seed: faults.seed)
        var output: [(TimeInterval, LocationFix)] = []
        for original in track {
            let elapsed = original.timestamp.timeIntervalSince(start)
            if faults.dropouts.contains(where: { $0.contains(elapsed) }) { continue }
            var fix = original
            var east = 0.0, north = 0.0
            if faults.jitterSigma > 0 {
                east += generator.gaussian() * faults.jitterSigma
                north += generator.gaussian() * faults.jitterSigma
            }
            for jump in faults.jumps where elapsed >= jump.at && elapsed < jump.at + jump.duration {
                east += jump.eastMeters
                north += jump.northMeters
            }
            if east != 0 || north != 0 {
                fix.coordinate = fix.coordinate.offset(eastMeters: east, northMeters: north)
            }
            output.append((elapsed, fix))
        }
        return output
    }

    public func fixStream() -> AsyncStream<LocationFix> {
        let events = prepared()
        let multiplier = speedMultiplier
        return AsyncStream { continuation in
            let task = Task {
                var previous: TimeInterval = 0
                for event in events {
                    if multiplier.isFinite, multiplier > 0, event.elapsed > previous {
                        try? await Task.sleep(nanoseconds: UInt64((event.elapsed - previous) / multiplier * 1_000_000_000))
                    }
                    if Task.isCancelled { break }
                    previous = event.elapsed
                    continuation.yield(event.fix)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Builds synthetic tracks for tests and the debug view.
public enum TrackBuilder {
    /// One fix every `interval` seconds, travelling along `geometry` at constant `speed` (m/s).
    public static func along(
        _ geometry: RouteGeometry,
        speed: Double,
        interval: TimeInterval = 1,
        start: Date = Date(timeIntervalSinceReferenceDate: 0),
        accuracy: Double = 5
    ) -> [LocationFix] {
        precondition(speed > 0 && interval > 0, "speed and interval must be positive")
        let step = speed * interval
        let count = Int(geometry.totalLength / step)
        return (0...count).map { i in
            let chainage = Double(i) * step
            return LocationFix(
                coordinate: geometry.coordinate(atChainage: chainage),
                timestamp: start.addingTimeInterval(Double(i) * interval),
                horizontalAccuracy: accuracy,
                speed: speed,
                course: geometry.bearing(atChainage: chainage)
            )
        }
    }
}
