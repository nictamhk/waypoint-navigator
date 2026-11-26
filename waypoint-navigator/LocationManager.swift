import CoreLocation
import Observation

/// Owns the CLLocationManager: asks for permission and publishes the user's position.
/// It knows nothing about maps or waypoints.
@MainActor
@Observable
final class LocationManager: NSObject, CLLocationManagerDelegate {

    /// Latest known position of the user (nil until the first GPS fix).
    private(set) var userCoordinate: CLLocationCoordinate2D?

    /// Current permission state.
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    var hasFix: Bool { userCoordinate != nil }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10 // metres; avoids a flood of tiny updates
    }

    /// Call once when the screen appears.
    func start() {
        handleAuthorizationChange(manager.authorizationStatus)
    }

    private func handleAuthorizationChange(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        default:
            manager.stopUpdatingLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate
    // These callbacks arrive on a system queue, so they hop back to the main actor.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.handleAuthorizationChange(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            self.userCoordinate = coordinate
        }
    }
}
