import SwiftUI
import MapKit

struct WaypointMapView: View {
    @State private var locationManager = LocationManager()
    @State var routeViewModel: RouteViewModel
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCentredOnUser = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Read the model once per redraw so SwiftUI reliably refreshes the map content.
        let waypoints = routeViewModel.waypoints
        let legs = routeViewModel.legs

        MapReader { mapProxy in
            Map(position: $cameraPosition) {
                UserAnnotation() // the blue dot

                // Driving route, one polyline per leg
                ForEach(legs) { leg in
                    MapPolyline(leg.polyline)
                        .stroke(.red, lineWidth: 5)
                }

                // Waypoint markers: START, numbered stops, END
                ForEach(waypoints) { waypoint in
                    Annotation("", coordinate: waypoint.coordinate) {
                        WaypointMarker(kind: routeViewModel.markerKind(for: waypoint))
                            .onTapGesture {
                                routeViewModel.removeWaypoint(waypoint)
                            }
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onTapGesture { screenPoint in
                addWaypoint(at: screenPoint, using: mapProxy)
            }
        }
        .overlay(alignment: .top) {
            statusPanel(waypointCount: waypoints.count, lastWaypoint: waypoints.last)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if let message = routeViewModel.errorMessage {
                    errorBanner(message)
                }
                if locationManager.isDenied {
                    permissionDeniedBanner
                }
                if !waypoints.isEmpty {
                    Button("Clear all", role: .destructive) {
                        routeViewModel.removeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Save as New Route") {
                        routeViewModel.saveAsNewRoute()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .task {
            locationManager.start()
        }
        .task(id: routeViewModel.waypointIDs) {
            await routeViewModel.updateRoute()
        }
        .onChange(of: locationManager.hasFix) { _, hasFix in
            centreOnUserOnce(hasFix: hasFix)
        }
    }

    // MARK: - Actions

    private func addWaypoint(at screenPoint: CGPoint, using mapProxy: MapProxy) {
        guard let coordinate = mapProxy.convert(screenPoint, from: .local) else { return }
        routeViewModel.addWaypoint(at: coordinate)
    }

    /// Moves the camera to the user the first time a location arrives.
    private func centreOnUserOnce(hasFix: Bool) {
        guard hasFix, !hasCentredOnUser, let coordinate = locationManager.userCoordinate else { return }
        hasCentredOnUser = true
        cameraPosition = .region(
            MKCoordinateRegion(center: coordinate,
                               latitudinalMeters: 1500,
                               longitudinalMeters: 1500)
        )
    }

    // MARK: - Subviews

    private func statusPanel(waypointCount: Int, lastWaypoint: MapWaypoint?) -> some View {
        VStack(spacing: 4) {
            Text("Waypoints: \(waypointCount)")
                .font(.headline)

            if let routeNumber = routeViewModel.routeNumber {
                Text("Route \(routeNumber)").font(.caption).foregroundStyle(.secondary)
            }

            if routeViewModel.hasCompleteRoute {
                Text("\(formattedDistance(routeViewModel.totalDistance)) · \(formattedDuration(routeViewModel.totalTravelTime))")
                    .font(.subheadline)
            } else if routeViewModel.isCalculating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Calculating route…").font(.subheadline)
                }
            }

            #if DEBUG
            // Temporary: shows where the last tap landed. Only appears in debug builds.
            if let last = lastWaypoint {
                Text(String(format: "Last: %.5f, %.5f", last.coordinate.latitude, last.coordinate.longitude))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.top, 8)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await routeViewModel.updateRoute() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionDeniedBanner: some View {
        VStack(spacing: 8) {
            Text("Location access is off. Turn it on in Settings to see your position.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Formatting

    private func formattedDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1000 { return "\(Int(meters.rounded())) m" }
        return String(format: "%.1f km", meters / 1000)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// Circular marker: green S (start), orange number (stop), red E (end).
private struct WaypointMarker: View {
    let kind: MarkerKind

    private var label: String {
        switch kind {
        case .start: return "S"
        case .end: return "E"
        case .stop(let number): return "\(number)"
        }
    }

    private var color: Color {
        switch kind {
        case .start: return .green
        case .end: return .red
        case .stop: return .orange
        }
    }

    var body: some View {
        Text(label)
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
            .contentShape(Circle())
    }
}

#Preview {
    WaypointMapView()
}
