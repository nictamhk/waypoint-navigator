import Foundation

/// Local east/north tangent-plane approximation around an origin.
/// Accurate to well under 0.1% for the few-kilometre extents we use it on
/// (one route segment at a time). Not intended for antimeridian-crossing routes.
struct LocalFrame {
    let origin: GeoCoordinate
    let metersPerDegreeLat: Double
    let metersPerDegreeLon: Double

    init(origin: GeoCoordinate) {
        let phi = origin.latitude * .pi / 180
        self.origin = origin
        metersPerDegreeLat = 111_132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi) - 0.0023 * cos(6 * phi)
        metersPerDegreeLon = 111_412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi)
    }

    func local(_ c: GeoCoordinate) -> (x: Double, y: Double) {
        ((c.longitude - origin.longitude) * metersPerDegreeLon,
         (c.latitude - origin.latitude) * metersPerDegreeLat)
    }

    func coordinate(x: Double, y: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + y / metersPerDegreeLat,
                      longitude: origin.longitude + x / metersPerDegreeLon)
    }
}

public extension GeoCoordinate {
    /// The coordinate `eastMeters` east and `northMeters` north of this one.
    func offset(eastMeters: Double, northMeters: Double) -> GeoCoordinate {
        LocalFrame(origin: self).coordinate(x: eastMeters, y: northMeters)
    }

    /// Planar-approximation distance in meters (intended for distances up to a few tens of km).
    func distance(to other: GeoCoordinate) -> Double {
        let reference = GeoCoordinate(latitude: (latitude + other.latitude) / 2, longitude: longitude)
        let frame = LocalFrame(origin: reference)
        let a = frame.local(self)
        let b = frame.local(other)
        return hypot(b.x - a.x, b.y - a.y)
    }

    /// Initial bearing to `other`, degrees clockwise from north, in [0, 360).
    func bearing(to other: GeoCoordinate) -> Double {
        let (x, y) = LocalFrame(origin: self).local(other)
        var degrees = atan2(x, y) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }
}
