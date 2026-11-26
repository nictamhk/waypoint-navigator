import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// A single location observation. Downstream code must use `timestamp`, never `Date()`,
/// so replayed tracks behave identically to live ones.
public struct LocationFix: Hashable, Codable, Sendable {
    public var coordinate: GeoCoordinate
    public var timestamp: Date
    /// Meters; larger is worse. Negative means invalid.
    public var horizontalAccuracy: Double
    /// m/s, nil when unknown.
    public var speed: Double?
    /// Degrees clockwise from north, nil when unknown.
    public var course: Double?
    public var speedAccuracy: Double?
    public var courseAccuracy: Double?
    /// True when the fix came from simulation (Xcode location simulation, mock providers).
    public var isSimulated: Bool

    public init(coordinate: GeoCoordinate, timestamp: Date, horizontalAccuracy: Double,
                speed: Double? = nil, course: Double? = nil,
                speedAccuracy: Double? = nil, courseAccuracy: Double? = nil,
                isSimulated: Bool = false) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.speedAccuracy = speedAccuracy
        self.courseAccuracy = courseAccuracy
        self.isSimulated = isSimulated
    }
}

#if canImport(CoreLocation)
public extension LocationFix {
    /// Converts a CLLocation, mapping Core Location's negative "unknown" values to nil.
    init(_ location: CLLocation) {
        self.init(
            coordinate: GeoCoordinate(location.coordinate),
            timestamp: location.timestamp,
            horizontalAccuracy: location.horizontalAccuracy,
            speed: location.speed >= 0 ? location.speed : nil,
            course: location.course >= 0 ? location.course : nil,
            speedAccuracy: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
            courseAccuracy: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
            isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false
        )
    }
}
#endif

/// Source of location fixes. `CoreLocationService` is the live implementation;
/// `ReplayLocationService` implements the same protocol for tests and the simulator.
public protocol LocationServicing: Sendable {
    /// Starts a new stream of fixes. Cancelling the consumer stops the source.
    func fixStream() -> AsyncStream<LocationFix>
}
