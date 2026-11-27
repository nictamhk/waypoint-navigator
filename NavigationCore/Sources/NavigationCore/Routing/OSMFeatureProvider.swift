import Foundation

public enum OSMFeatureProviderError: Error { case invalidResponse, httpStatus(Int) }

/// Fetches stop candidates and expressway ways from the public Overpass API.
public struct OSMFeatureProvider: Sendable {
    public var endpoint: URL
    public var session: URLSession

    public init(endpoint: URL = URL(string: "https://overpass-api.de/api/interpreter")!, session: URLSession = .shared) {
        self.endpoint = endpoint; self.session = session
    }

    public func features(for geometry: RouteGeometry) async throws -> (features: [StopFeature], highwayWays: [HighwayWay]) {
        guard !geometry.vertices.isEmpty else { return ([], []) }
        let latitudes = geometry.vertices.map(\.latitude), longitudes = geometry.vertices.map(\.longitude)
        let latitudePadding = 0.001
        let midLatitude = (latitudes.min()! + latitudes.max()!) / 2 * .pi / 180
        let longitudePadding = 50 / max(111_000 * abs(cos(midLatitude)), 1)
        let south = latitudes.min()! - latitudePadding, north = latitudes.max()! + latitudePadding
        let west = longitudes.min()! - longitudePadding, east = longitudes.max()! + longitudePadding
        let bbox = "\(south),\(west),\(north),\(east)"
        let query = "[out:json][timeout:25];(node[highway=bus_stop](\(bbox));node[public_transport=platform](\(bbox));node[highway=traffic_signals](\(bbox));node[highway=motorway_junction](\(bbox));node[tourism~\"^(attraction|museum|viewpoint)$\"](\(bbox));node[historic](\(bbox));node[amenity~\"^(hospital|university|place_of_worship)$\"](\(bbox));way[highway~\"^(motorway|trunk)$\"][expressway=yes](\(bbox)););out body;>;out skel qt;"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = "data=" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OSMFeatureProviderError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw OSMFeatureProviderError.httpStatus(response.statusCode) }
        return try parse(data)
    }

    private func parse(_ data: Data) throws -> (features: [StopFeature], highwayWays: [HighwayWay]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw OSMFeatureProviderError.invalidResponse }
        var nodes: [Int: GeoCoordinate] = [:], features: [StopFeature] = [], ways: [HighwayWay] = []
        for item in elements where item["type"] as? String == "node" {
            guard let id = item["id"] as? Int, let lat = item["lat"] as? Double, let lon = item["lon"] as? Double else { continue }
            let coordinate = GeoCoordinate(latitude: lat, longitude: lon); nodes[id] = coordinate
            guard let tags = item["tags"] as? [String: String] else { continue }
            let kind: StopFeatureKind?
            if tags["highway"] == "motorway_junction" { kind = .highwayExit }
            else if tags["highway"] == "bus_stop" || tags["public_transport"] == "platform" { kind = .busStop }
            else if tags["highway"] == "traffic_signals" { kind = .signalizedMajorIntersection }
            else if tags["tourism"] != nil || tags["historic"] != nil || ["hospital", "university", "place_of_worship"].contains(tags["amenity"] ?? "") { kind = .landmark }
            else { kind = nil }
            if let kind {
                let detail = tags["exit_to"] ?? tags["destination"]
                features.append(StopFeature(id: "node/\(id)", coordinate: coordinate, kind: kind,
                                            name: tags["name"], ref: tags["ref"], detail: detail))
            }
        }
        for item in elements where item["type"] as? String == "way" {
            guard let id = item["id"] as? Int, let tags = item["tags"] as? [String: String],
                  let highway = tags["highway"], let refs = item["nodes"] as? [Int] else { continue }
            let coordinates = refs.compactMap { nodes[$0] }
            if coordinates.count >= 2 {
                ways.append(HighwayWay(id: "way/\(id)", coordinates: coordinates,
                                       highway: highway, expressway: tags["expressway"] == "yes"))
            }
        }
        return (features, ways)
    }
}
