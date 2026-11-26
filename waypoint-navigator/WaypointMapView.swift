import SwiftUI
import MapKit

struct WaypointMapView: View {
    @State private var locationManager = LocationManager()
    @State private var routeViewModel = RouteViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCentredOnUser = false
    @State private var isEditingWaypoints = false
    @State private var isShowingSavePrompt = false
    @State private var saveRouteName = ""

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
                    Annotation("", coordinate: routeViewModel.displayedCoordinate(for: waypoint)) {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            waypointPanel(waypoints: waypoints)
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
        .alert("Save route", isPresented: $isShowingSavePrompt) {
            TextField("Route name", text: $saveRouteName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                routeViewModel.saveRoute(named: saveRouteName)
            }
        } message: {
            Text("Save this waypoint order on this iPhone.")
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

    private func waypointPanel(waypoints: [MapWaypoint]) -> some View {
        VStack(spacing: 0) {
            if !waypoints.isEmpty {
                HStack {
                    Text("Waypoints · \(waypoints.count)")
                        .font(.headline)
                    Spacer()
                    Button(isEditingWaypoints ? "Done" : "Reorder") {
                        withAnimation { isEditingWaypoints.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .disabled(waypoints.count < 2)
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 4)

                List {
                    ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                        waypointRow(waypoint, index: index, count: waypoints.count)
                            .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                            .listRowBackground(Color.clear)
                    }
                    .onMove { source, destination in
                        routeViewModel.moveWaypoints(from: source, to: destination)
                    }
                    .onDelete(perform: routeViewModel.removeWaypoints(at:))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(isEditingWaypoints ? .active : .inactive))
                .frame(height: min(CGFloat(waypoints.count) * 58, 232))

                HStack(spacing: 12) {
                    if routeViewModel.hasCompleteRoute {
                        Text("Total · \(formattedDuration(routeViewModel.totalTravelTime))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if routeViewModel.isCalculating {
                        ProgressView().controlSize(.small)
                        Text("Estimating…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        saveRouteName = "Route \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                        isShowingSavePrompt = true
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!routeViewModel.hasCompleteRoute)

                    Button("Clear", role: .destructive) {
                        routeViewModel.removeAll()
                        isEditingWaypoints = false
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.vertical, 9)

                if let message = routeViewModel.saveMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(message.hasPrefix("Could not") ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
            }

            if let message = routeViewModel.errorMessage {
                errorBanner(message)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
            if locationManager.isDenied {
                permissionDeniedBanner
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .background(.regularMaterial)
    }

    private func waypointRow(_ waypoint: MapWaypoint, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            WaypointMarker(kind: routeViewModel.markerKind(for: waypoint))
                .scaleEffect(0.78)
                .frame(width: 30, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(waypointTitle(at: index, count: count))
                    .font(.subheadline.weight(.medium))
                Text(String(format: "%.5f, %.5f", waypoint.coordinate.latitude, waypoint.coordinate.longitude))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(index == 0 ? "Start" : routeViewModel.estimatedLegTime(at: index).map { "Leg · \(formattedDuration($0))" } ?? "Leg · pending")
                    .font(.subheadline)
                Text("ETA · \(routeViewModel.estimatedArrival(at: index)?.formatted(date: .omitted, time: .shortened) ?? "pending")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func waypointTitle(at index: Int, count: Int) -> String {
        if index == 0 { return "Start" }
        if index == count - 1 { return "Terminus" }
        return "Stop \(index)"
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
