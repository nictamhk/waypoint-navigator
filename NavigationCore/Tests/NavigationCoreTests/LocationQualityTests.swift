import XCTest
@testable import NavigationCore
#if canImport(CoreLocation)
import CoreLocation
#endif

func makeFix(north: Double, east: Double = 0, t: Double, accuracy: Double = 5,
             speed: Double? = 10, course: Double? = 0) -> LocationFix {
    LocationFix(coordinate: Fixture.origin.offset(eastMeters: east, northMeters: north),
                timestamp: Date(timeIntervalSinceReferenceDate: t),
                horizontalAccuracy: accuracy, speed: speed, course: course)
}

final class LocationQualityTests: XCTestCase {
    func testAccuracyTiers() {
        var filter = LocationQualityFilter()
        XCTAssertEqual(filter.assess(makeFix(north: 0, t: 0, accuracy: 10)), .good)
        XCTAssertEqual(filter.assess(makeFix(north: 10, t: 1, accuracy: 35)), .degraded)
        XCTAssertEqual(filter.assess(makeFix(north: 20, t: 2, accuracy: 80)), .rejected(.poorAccuracy))
        XCTAssertEqual(filter.assess(makeFix(north: 30, t: 3, accuracy: -1)), .rejected(.invalidAccuracy))
    }

    func testStaleFixIsRejected() {
        var filter = LocationQualityFilter()
        let fix = makeFix(north: 0, t: 0)
        XCTAssertEqual(filter.assess(fix, now: Date(timeIntervalSinceReferenceDate: 30)), .rejected(.stale))
        XCTAssertEqual(filter.assess(fix, now: Date(timeIntervalSinceReferenceDate: 3)), .good)
    }

    func testOutOfOrderAndDuplicateTimestampsAreRejected() {
        var filter = LocationQualityFilter()
        XCTAssertEqual(filter.assess(makeFix(north: 0, t: 10)), .good)
        XCTAssertEqual(filter.assess(makeFix(north: 10, t: 9)), .rejected(.outOfOrder))
        XCTAssertEqual(filter.assess(makeFix(north: 10, t: 10)), .rejected(.outOfOrder))
        XCTAssertEqual(filter.assess(makeFix(north: 10, t: 11)), .good)
    }

    func testImplausibleJumpIsRejectedThenRecovers() {
        var filter = LocationQualityFilter()
        XCTAssertEqual(filter.assess(makeFix(north: 0, t: 0)), .good)
        XCTAssertEqual(filter.assess(makeFix(north: 400, t: 1)), .rejected(.implausibleJump))
        XCTAssertEqual(filter.assess(makeFix(north: 20, t: 2)), .good)
    }

    func testSustainedOffsetIsAcceptedAfterFiveRejections() {
        var filter = LocationQualityFilter()
        _ = filter.assess(makeFix(north: 0, t: 0))
        for t in 1...4 {
            XCTAssertEqual(filter.assess(makeFix(north: 400, t: Double(t))), .rejected(.implausibleJump), "t=\(t)")
        }
        XCTAssertEqual(filter.assess(makeFix(north: 400, t: 5)), .good)
    }

    func testSimulatedFixesRejectedOnlyWhenConfigured() {
        var fix = makeFix(north: 0, t: 0)
        fix.isSimulated = true
        var lenient = LocationQualityFilter()
        XCTAssertEqual(lenient.assess(fix), .good)
        var configuration = LocationQualityFilter.Configuration()
        configuration.rejectSimulated = true
        var strict = LocationQualityFilter(configuration: configuration)
        XCTAssertEqual(strict.assess(fix), .rejected(.simulated))
    }
}

final class SignalMonitorTests: XCTestCase {
    private func time(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }

    func testLifecycle() {
        var monitor = SignalMonitor()
        XCTAssertEqual(monitor.state, .acquiring)
        XCTAssertEqual(monitor.tick(at: time(100)), .acquiring)

        XCTAssertEqual(monitor.record(.good, at: time(0)), .good)
        XCTAssertEqual(monitor.tick(at: time(4)), .good)
        XCTAssertEqual(monitor.tick(at: time(6)), .degraded)
        XCTAssertEqual(monitor.tick(at: time(16)), .lost)
        XCTAssertEqual(monitor.record(.good, at: time(20)), .good)
    }

    func testRejectedFixesDoNotResetTheGapClock() {
        var monitor = SignalMonitor()
        monitor.record(.good, at: time(0))
        XCTAssertEqual(monitor.record(.rejected(.poorAccuracy), at: time(6)), .degraded)
        XCTAssertEqual(monitor.record(.rejected(.poorAccuracy), at: time(16)), .lost)
    }

    func testDegradedVerdictSetsDegradedState() {
        var monitor = SignalMonitor()
        XCTAssertEqual(monitor.record(.degraded, at: time(0)), .degraded)
        XCTAssertEqual(monitor.record(.good, at: time(1)), .good)
    }
}

#if canImport(CoreLocation)
final class LocationFixConversionTests: XCTestCase {
    func testUnknownValuesBecomeNil() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -75), altitude: 0,
            horizontalAccuracy: 12, verticalAccuracy: -1, course: -1, courseAccuracy: -1,
            speed: -1, speedAccuracy: -1, timestamp: Date(timeIntervalSinceReferenceDate: 5))
        let fix = LocationFix(location)
        XCTAssertEqual(fix.horizontalAccuracy, 12)
        XCTAssertNil(fix.speed)
        XCTAssertNil(fix.course)
        XCTAssertNil(fix.speedAccuracy)
        XCTAssertNil(fix.courseAccuracy)
    }

    func testValidValuesAreKept() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -75), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 5, course: 90, courseAccuracy: 10,
            speed: 8.5, speedAccuracy: 0.7, timestamp: Date(timeIntervalSinceReferenceDate: 5))
        let fix = LocationFix(location)
        XCTAssertEqual(fix.speed, 8.5)
        XCTAssertEqual(fix.course, 90)
        XCTAssertEqual(fix.speedAccuracy, 0.7)
        XCTAssertEqual(fix.courseAccuracy, 10)
        XCTAssertEqual(fix.coordinate.latitude, 45, accuracy: 1e-9)
    }
}
#endif
