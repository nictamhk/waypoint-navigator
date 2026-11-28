import CoreLocation

struct PlaceInfo {
    let address: String?
    let neighbourhood: String?
}

/// Reverse-geocodes coordinates one at a time. Apple throttles geocoding, so requests are spaced
/// at least 1.2 s apart, and successful results are remembered for the life of the app.
///
/// Name = house number + street, else street, else place name, else locality.
actor AddressResolver {
    private var cache: [String: PlaceInfo] = [:]
    private var nextSlot = Date.distantPast
    private let minimumGap: TimeInterval = 1.2

    func address(at coordinate: CLLocationCoordinate2D) async -> String? {
        await placeInfo(at: coordinate)?.address
    }

    func neighbourhood(at coordinate: CLLocationCoordinate2D) async -> String? {
        await placeInfo(at: coordinate)?.neighbourhood
    }

    func placeInfo(at coordinate: CLLocationCoordinate2D) async -> PlaceInfo? {
        let key = String(format: "%.5f,%.5f", coordinate.latitude, coordinate.longitude)
        if let cached = cache[key] { return cached }

        // Reserve a time slot before waiting, so overlapping callers still end up spaced apart.
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(minimumGap)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if Task.isCancelled { return nil }

        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard let placemark = placemarks.first else { return nil }
            let info = PlaceInfo(address: Self.name(from: placemark), neighbourhood: placemark.subLocality)
            cache[key] = info
            return info
        } catch {
            return nil
        }
    }

    private static func name(from placemark: CLPlacemark) -> String? {
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        if !street.isEmpty { return street }
        if let name = placemark.name, !name.isEmpty { return name }
        return placemark.locality ?? placemark.subLocality
    }
}
