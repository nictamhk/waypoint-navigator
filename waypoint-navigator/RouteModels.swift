import MapKit

/// The locally saved form of a route being assembled in the map editor.
struct SavedWaypoint: Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let title: String?
    /// Estimated drive time from the previous waypoint; nil for the route origin.
    let travelTimeFromPrevious: TimeInterval?
    let estimatedArrival: Date?

    init(id: UUID, coordinate: CLLocationCoordinate2D, title: String?,
         travelTimeFromPrevious: TimeInterval?, estimatedArrival: Date?) {
        self.id = id
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.title = title
        self.travelTimeFromPrevious = travelTimeFromPrevious
        self.estimatedArrival = estimatedArrival
    }

    private enum CodingKeys: String, CodingKey {
        case id, latitude, longitude, title, travelTimeFromPrevious, estimatedArrival
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        travelTimeFromPrevious = try values.decodeIfPresent(TimeInterval.self, forKey: .travelTimeFromPrevious)
        estimatedArrival = try values.decodeIfPresent(Date.self, forKey: .estimatedArrival)
    }
}

struct SavedCoordinate: Codable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }
}

struct SavedRouteColor: Codable, Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let blue = SavedRouteColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
}

struct SavedRoute: Codable, Identifiable {
    let id: UUID
    var routeNumber: String
    var name: String
    var color: SavedRouteColor
    let savedAt: Date
    let waypoints: [SavedWaypoint]
    let polyline: [SavedCoordinate]

    init(id: UUID = UUID(), routeNumber: String, name: String, color: SavedRouteColor,
         savedAt: Date = .now, waypoints: [SavedWaypoint], polyline: [SavedCoordinate]) {
        self.id = id
        self.routeNumber = routeNumber
        self.name = name
        self.color = color
        self.savedAt = savedAt
        self.waypoints = waypoints
        self.polyline = polyline
    }

    private enum CodingKeys: String, CodingKey {
        case id, routeNumber, name, color, savedAt, waypoints, polyline
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        routeNumber = try values.decodeIfPresent(String.self, forKey: .routeNumber) ?? ""
        name = try values.decode(String.self, forKey: .name)
        color = try values.decodeIfPresent(SavedRouteColor.self, forKey: .color) ?? .blue
        savedAt = try values.decodeIfPresent(Date.self, forKey: .savedAt) ?? .now
        waypoints = try values.decode([SavedWaypoint].self, forKey: .waypoints)
        polyline = try values.decodeIfPresent([SavedCoordinate].self, forKey: .polyline) ?? []
    }
}

/// Small local JSON store for routes finalized in the current prototype.
enum SavedRouteStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("saved-routes.json")
    }

    static func loadAll() throws -> [SavedRoute] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedRoute].self, from: Data(contentsOf: fileURL))
    }

    static func append(_ route: SavedRoute) throws {
        let routes = try loadAll()
        let updatedRoutes = routes + [route]
        let data = try JSONEncoder().encode(updatedRoutes)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// One tapped point on the map.
/// (Named MapWaypoint so it cannot clash with a Waypoint type in NavigationCore.)
struct MapWaypoint: Identifiable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(id: UUID = UUID(), coordinate: CLLocationCoordinate2D, title: String? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.title = title
    }
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
