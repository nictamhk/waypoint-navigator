import MapKit

/// One tapped point on the map.
/// (Named MapWaypoint so it cannot clash with a Waypoint type in NavigationCore.)
struct MapWaypoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

/// Identifies one leg of the route: "from this waypoint to that waypoint".
struct LegKey: Hashable {
    let from: UUID
    let to: UUID
}

/// The driving route between two consecutive waypoints, as returned by Apple Maps.
struct DrivingLeg: Identifiable {
    let key: LegKey
    let polyline: MKPolyline
    let distance: CLLocationDistance   // metres
    let travelTime: TimeInterval       // seconds, includes expected traffic

    var id: LegKey { key }
}

/// How a marker is drawn, following the wireframe: START, numbered stops, END.
enum MarkerKind {
    case start
    case stop(Int)
    case end
}
