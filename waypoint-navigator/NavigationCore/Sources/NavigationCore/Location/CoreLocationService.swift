#if canImport(CoreLocation)
import CoreLocation
import Foundation

public enum LocationAuthorization: String, Sendable, Equatable {
    case notDetermined, denied, restricted, whenInUse, always
}

/// Live Core Location source for navigation.
///
/// - Create it on the main actor. All Core Location interaction happens on the main thread.
/// - Needs `NSLocationWhenInUseUsageDescription` in the app's Info.
/// - Background updates are enabled only if `UIBackgroundModes` contains "location"; setting
///   `allowsBackgroundLocationUpdates` without it raises an exception, so this is checked first.
public final class CoreLocationService: NSObject, CLLocationManagerDelegate, LocationServicing, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBestForNavigation
        public var activityType: CLActivityType = .automotiveNavigation
        public var requestsBackgroundUpdates = true
        public init() {}
    }

    private let manager: CLLocationManager
    private let configuration: Configuration
    private var fixContinuations: [UUID: AsyncStream<LocationFix>.Continuation] = [:]
    private var authorizationContinuations: [UUID: AsyncStream<LocationAuthorization>.Continuation] = [:]
    private var isUpdating = false

    @MainActor
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = configuration.desiredAccuracy
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = configuration.activityType
        #if os(iOS)
        manager.pausesLocationUpdatesAutomatically = false
        #endif
    }

    public var hasFullAccuracy: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    #if os(iOS)
    /// Asks for temporary full accuracy. The purpose key must exist in `NSLocationTemporaryUsageDescriptionDictionary`.
    @MainActor
    public func requestFullAccuracy(purposeKey: String) async throws {
        try await manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: purposeKey)
    }
    #endif

    // MARK: LocationServicing

    public func fixStream() -> AsyncStream<LocationFix> {
        AsyncStream { continuation in
            let id = UUID()
            DispatchQueue.main.async { [self] in
                fixContinuations[id] = continuation
                startIfNeeded()
            }
            continuation.onTermination = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.fixContinuations[id] = nil
                    self?.stopIfIdle()
                }
            }
        }
    }

    /// Emits the current authorization immediately, then every change.
    public func authorizationStream() -> AsyncStream<LocationAuthorization> {
        AsyncStream { continuation in
            let id = UUID()
            DispatchQueue.main.async { [self] in
                authorizationContinuations[id] = continuation
                continuation.yield(Self.map(manager.authorizationStatus))
            }
            continuation.onTermination = { [weak self] _ in
                DispatchQueue.main.async { self?.authorizationContinuations[id] = nil }
            }
        }
    }

    // MARK: Start / stop (main thread only)

    private static var hasLocationBackgroundMode: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }

    private func startIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()   // updates begin in locationManagerDidChangeAuthorization
        case .authorizedWhenInUse, .authorizedAlways:
            beginUpdates()
        default:
            break   // denied or restricted: surfaced through authorizationStream
        }
    }

    private func beginUpdates() {
        guard !isUpdating else { return }
        #if os(iOS)
        if configuration.requestsBackgroundUpdates && Self.hasLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        #endif
        manager.startUpdatingLocation()
        isUpdating = true
    }

    private func stopIfIdle() {
        guard fixContinuations.isEmpty, isUpdating else { return }
        manager.stopUpdatingLocation()
        isUpdating = false
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedWhenInUse: return .whenInUse
        case .authorizedAlways: return .always
        default: return .denied
        }
    }

    // MARK: CLLocationManagerDelegate

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for location in locations {
            let fix = LocationFix(location)
            for continuation in fixContinuations.values { continuation.yield(fix) }
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = Self.map(manager.authorizationStatus)
        for continuation in authorizationContinuations.values { continuation.yield(authorization) }
        if (authorization == .whenInUse || authorization == .always) && !fixContinuations.isEmpty {
            beginUpdates()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient and Core Location keeps trying; denial is reported
        // through the authorization stream. Signal loss is detected by SignalMonitor's watchdog.
    }
}
#endif
