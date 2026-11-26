import XCTest
@testable import NavigationCore

private func collect(_ stream: AsyncStream<LocationFix>) async -> [LocationFix] {
    var fixes: [LocationFix] = []
    for await fix in stream { fixes.append(fix) }
    return fixes
}

final class MatchingTests: XCTestCase {
    private func northRoute() throws -> RouteGeometry {
        try RouteGeometry(legs: [Fixture.path([(0, 0), (0, 1000), (0, 2000)])])
    }

    func testCleanTrackMatchesTruth() throws {
        let geometry = try northRoute()
        var service = RouteMatchingService(geometry: geometry)
        for (i, fix) in TrackBuilder.along(geometry, speed: 10).enumerated() {
            let observation = service.ingest(fix)
            let match = try XCTUnwrap(observation.match, "fix \(i)")
            XCTAssertEqual(match.chainage, Double(i) * 10, accuracy: 1.0, "fix \(i)")
            XCTAssertEqual(observation.signal, .good)
            XCTAssertTrue(observation.isReliable, "fix \(i)")
        }
    }

    func testJitteredTrackIsSmoothedAndProgressIsMonotonic() async throws {
        let geometry = try northRoute()
        var faults = ReplayLocationService.Faults()
        faults.jitterSigma = 5
        let fixes = await collect(ReplayLocationService(
            track: TrackBuilder.along(geometry, speed: 10), speedMultiplier: .infinity, faults: faults).fixStream())

        var service = RouteMatchingService(geometry: geometry)
        var squares: [Double] = []
        var lastProgress = 0.0
        for (i, fix) in fixes.enumerated() {
            let match = try XCTUnwrap(service.ingest(fix).match, "fix \(i)")
            squares.append(pow(match.chainage - Double(i) * 10, 2))
            XCTAssertGreaterThanOrEqual(match.progress, lastProgress)
            lastProgress = match.progress
        }
        let rms = (squares.reduce(0, +) / Double(squares.count)).squareRoot()
        XCTAssertLessThan(rms, 5)   // raw along-track noise is 5 m RMS; the filter should do better
    }

    func testOverlappingRouteChoosesTheCorrectPass() throws {
        // Square loop, then back along the first side: (50, 0) is at chainage 50 and again at 850.
        let geometry = try RouteGeometry(legs: [Fixture.path([(0, 0), (200, 0), (200, 200), (0, 200), (0, 0), (100, 0)])])
        var service = RouteMatchingService(geometry: geometry)
        for (i, fix) in TrackBuilder.along(geometry, speed: 10).enumerated() {
            let match = try XCTUnwrap(service.ingest(fix).match, "fix \(i)")
            XCTAssertEqual(match.chainage, Double(i) * 10, accuracy: 3, "fix \(i)")
            XCTAssertFalse(match.wasReacquired, "fix \(i)")
        }
    }

    func testParallelRoadShowsLateralOffsetAndLowConfidence() throws {
        let geometry = try RouteGeometry(legs: [Fixture.path([(0, 0), (1000, 0)])])   // eastbound
        var service = RouteMatchingService(geometry: geometry)
        let observation = service.ingest(makeFix(north: 40, east: 500, t: 0, course: 90))
        let match = try XCTUnwrap(observation.match)
        XCTAssertEqual(match.chainage, 500, accuracy: 1)
        XCTAssertEqual(match.lateralOffset, -40, accuracy: 0.5)   // north of an eastbound route = left = negative
        XCTAssertEqual(match.confidence, .low)
        XCTAssertFalse(observation.isReliable)
    }

    func testJumpFixesAreRejectedAndMatchingContinues() async throws {
        let geometry = try northRoute()
        var faults = ReplayLocationService.Faults()
        faults.jumps = [.init(at: 100, duration: 3, eastMeters: 400, northMeters: 0)]
        let fixes = await collect(ReplayLocationService(
            track: TrackBuilder.along(geometry, speed: 10), speedMultiplier: .infinity, faults: faults).fixStream())

        var service = RouteMatchingService(geometry: geometry)
        var rejected: [Int] = []
        for (i, fix) in fixes.enumerated() {
            let observation = service.ingest(fix)
            if case .rejected = observation.verdict {
                rejected.append(i)
            } else {
                XCTAssertEqual(try XCTUnwrap(observation.match).chainage, Double(i) * 10, accuracy: 3, "fix \(i)")
            }
        }
        XCTAssertEqual(rejected, [100, 101, 102])
    }

    func testSignalLossAndReacquisitionAfterLongGap() throws {
        var service = RouteMatchingService(geometry: try northRoute())
        for k in 0...50 { _ = service.ingest(makeFix(north: Double(k) * 10, t: Double(k))) }

        XCTAssertEqual(service.tick(now: Date(timeIntervalSinceReferenceDate: 53)), .good)
        XCTAssertEqual(service.tick(now: Date(timeIntervalSinceReferenceDate: 56)), .degraded)
        XCTAssertEqual(service.tick(now: Date(timeIntervalSinceReferenceDate: 70)), .lost)

        let observation = service.ingest(makeFix(north: 1100, t: 110))   // 60 s later, 600 m further on
        XCTAssertEqual(observation.signal, .good)
        XCTAssertEqual(try XCTUnwrap(observation.match).chainage, 1100, accuracy: 3)
    }

    func testDrivingBackwardsIsDetected() throws {
        var service = RouteMatchingService(geometry: try northRoute())
        for k in 0...50 {
            let match = try XCTUnwrap(service.ingest(makeFix(north: Double(k) * 10, t: Double(k))).match)
            XCTAssertFalse(match.isReversing)
        }
        var last: RouteMatch?
        for k in 1...8 {
            last = service.ingest(makeFix(north: 500 - Double(k) * 10, t: 50 + Double(k), speed: 10, course: 180)).match
        }
        let match = try XCTUnwrap(last)
        XCTAssertTrue(match.isReversing)
        XCTAssertEqual(try XCTUnwrap(match.headingDelta), 180, accuracy: 1)
        XCTAssertGreaterThan(match.progress, 495)   // progress never goes backwards
    }

    func testStationaryJitterDoesNotDriftChainage() throws {
        var service = RouteMatchingService(geometry: try northRoute())
        var chainages: [Double] = []
        for k in 0..<40 {
            let jitter = k % 2 == 0 ? 4.0 : -4.0
            let match = try XCTUnwrap(service.ingest(makeFix(north: 500 + jitter, t: Double(k), speed: 0, course: nil)).match)
            chainages.append(match.chainage)
        }
        let spread = (chainages.max() ?? 0) - (chainages.min() ?? 0)
        XCTAssertLessThan(spread, 8)
    }

    func testFarFromRouteStillReturnsLowConfidenceMatch() throws {
        var service = RouteMatchingService(geometry: try northRoute())
        _ = service.ingest(makeFix(north: 500, t: 0))
        let match = try XCTUnwrap(service.ingest(makeFix(north: 520, east: 600, t: 60)).match)
        XCTAssertEqual(match.confidence, .low)
        XCTAssertGreaterThan(match.distanceToRoute, 500)
    }

    func testReplacingGeometryRestartsProgress() throws {
        var service = RouteMatchingService(geometry: try northRoute())
        for k in 0...20 { _ = service.ingest(makeFix(north: Double(k) * 10, t: Double(k))) }
        service.replaceGeometry(try RouteGeometry(legs: [Fixture.path([(0, 150), (0, 900)])]))
        let match = try XCTUnwrap(service.ingest(makeFix(north: 300, t: 21)).match)
        XCTAssertEqual(match.chainage, 150, accuracy: 1)   // 150 m along the new route
        XCTAssertEqual(match.progress, match.chainage, accuracy: 0.001)
    }
}
