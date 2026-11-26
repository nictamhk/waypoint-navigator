import MapKit

/// The locally saved form of a route being assembled in the map editor.
struct SavedWaypoint: Codable {
    let latitude: Double
    let longitude: Double

    init(coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

struct SavedRoute: Codable, Identifiable {
    let id: UUID
    var name: String
    let savedAt: Date
    let waypoints: [SavedWaypoint]

    init(name: String, waypoints: [MapWaypoint]) {
        id = UUID()
        self.name = name
        savedAt = Date()
        self.waypoints = waypoints.map { SavedWaypoint(coordinate: $0.coordinate) }
    }
}

/// Small local JSON store for routes finalized in the current prototype.
enum SavedRouteStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("saved-routes.json")
    }

    static func append(_ route: SavedRoute) throws {
        let routes = (try? JSONDecoder().decode([SavedRoute].self, from: Data(contentsOf: fileURL))) ?? []
        let updatedRoutes = routes + [route]
        let data = try JSONEncoder().encode(updatedRoutes)
        try data.write(to: fileURL, options: .atomic)
    }
}

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
