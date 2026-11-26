import Foundation
#if canImport(MapKit)
import MapKit
#endif

public struct DirectionsResult: Sendable, Equatable {
    public let coordinates: [GeoCoordinate]
    public let distance: Double
    public let expectedTravelTime: TimeInterval

    public init(coordinates: [GeoCoordinate], distance: Double, expectedTravelTime: TimeInterval) {
        self.coordinates = coordinates
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
    }
}

public enum DirectionsError: Error, Equatable, Sendable {
    case noRoute
    case throttled
    case network
    case unknown(String)
}

/// Abstraction over MapKit so routing can be stubbed in tests.
public protocol DirectionsProviding: Sendable {
    func route(from: GeoCoordinate, to: GeoCoordinate, departure: Date?) async throws -> DirectionsResult
}

#if canImport(MapKit)
/// One `MKDirections` request per leg, driving.
public struct MapKitDirectionsProvider: DirectionsProviding {
    public init() {}

    public func route(from: GeoCoordinate, to: GeoCoordinate, departure: Date?) async throws -> DirectionsResult {
        let request = MKDirections.Request()
        // MKPlacemark/MKMapItem(placemark:) is deprecated from iOS 26 in favour of MKMapItem(location:address:);
        // both work on iOS 17. Swap when you raise the deployment target.
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from.clCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to.clCoordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        // Phase 0 spike: verify whether departureDate changes expectedTravelTime for .automobile.
        if let departure { request.departureDate = departure }

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else { throw DirectionsError.noRoute }
            let polyline = route.polyline
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
            polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
            return DirectionsResult(
                coordinates: coordinates.map { GeoCoordinate($0) },
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime
            )
        } catch let error as DirectionsError {
            throw error
        } catch let error as MKError {
            switch error.code {
            case .loadingThrottled: throw DirectionsError.throttled
            case .directionsNotFound: throw DirectionsError.noRoute
            case .serverFailure: throw DirectionsError.network
            default: throw DirectionsError.unknown(error.localizedDescription)
            }
        } catch is URLError {
            throw DirectionsError.network
        } catch {
            if error is CancellationError { throw error }
            throw DirectionsError.unknown(error.localizedDescription)
        }
    }
}
#endif
