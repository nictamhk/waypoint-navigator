import SwiftUI
import MapKit
import UIKit

struct WaypointMapView: View {
    @State private var locationManager = LocationManager()
    @State private var routeViewModel = RouteViewModel()
    @State private var cameraPosition: MapCameraPosition = .userLocation(followsHeading: false, fallback: .automatic)
    @State private var hasCentredOnUser = false
    @State private var isEditingWaypoints = false
    @State private var isShowingSaveForm = false
    @State private var routeNumberInput = ""
    @State private var routeNameInput = ""
    @State private var selectedRouteColor: Color = .blue
    @State private var routeCreationMode: RouteCreationMode = .manual
    @State private var isShowingRouteLibrary = false
    @State private var savedRoutes: [SavedRoute] = []
    @State private var selectedPresetID: UUID?
    @State private var presetError: String?
    @State private var automaticDestination: MapWaypoint?
    @State private var stopIntervalMeters = 1_000.0
    @State private var isExpressModeEnabled = false
    @State private var isGeneratingRoute = false
    @State private var automaticRouteTask: Task<Void, Never>?
    @State private var automaticGenerationID = UUID()
    @State private var addressQuery = ""
    @State private var addressResults: [AddressSearchResult] = []
    @State private var isSearchingAddress = false
    @State private var addressSearchMessage: String?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var isMapExpanded = false
    @FocusState private var isAddressSearchFocused: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Read the model once per redraw so SwiftUI reliably refreshes the map content.
        let waypoints = routeViewModel.waypoints
        let legs = routeViewModel.legs

        GeometryReader { geometry in
            VStack(spacing: 10) {
                routeHeader

                routeModePicker

                mapPreview(waypoints: waypoints, legs: legs)
                    .frame(height: isMapExpanded
                           ? min(max(geometry.size.height * 0.52, 300), 520)
                           : min(max(geometry.size.height * 0.29, 180), 280))

                routeModePanel(
                    waypoints: waypoints,
                    waypointListHeight: isMapExpanded ? 72 : min(max(geometry.size.height * 0.22, 110), 210),
                    isCompact: isMapExpanded
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .task { locationManager.start() }
        .task(id: routeViewModel.routeTaskID) { await routeViewModel.updateRoute() }
        .onChange(of: locationManager.hasFix) { _, hasFix in centreOnUserOnce(hasFix: hasFix) }
        .sheet(isPresented: $isShowingSaveForm) { saveRouteForm }
        .fullScreenCover(isPresented: $isShowingRouteLibrary) {
            RouteLibraryView { route in
                routeViewModel.loadSavedRoute(route)
                selectedPresetID = route.id
                automaticDestination = nil
            }
        }
        .onChange(of: routeCreationMode) { _, mode in
            isMapExpanded = false
            automaticGenerationID = UUID()
            automaticRouteTask?.cancel()
            automaticRouteTask = nil
            isGeneratingRoute = false
            routeViewModel.resetDraft(defaultStart: locationManager.userCoordinate)
            automaticDestination = nil
            addressQuery = ""
            addressResults = []
            addressSearchMessage = nil
            selectedPresetID = nil
            isEditingWaypoints = false
            isAddressSearchFocused = false
            if let coordinate = locationManager.userCoordinate {
                cameraPosition = .region(neighborhoodRegion(center: coordinate))
            }
            if mode == .loadPreset { refreshSavedRoutes() }
        }
        .onChange(of: routeViewModel.savedRoute?.id) { _, _ in refreshSavedRoutes() }
    }

    // MARK: - Actions

    private func mapPreview(waypoints: [MapWaypoint], legs: [DrivingLeg]) -> some View {
        MapReader { mapProxy in
            Map(position: $cameraPosition) {
                UserAnnotation()

                if routeViewModel.hasCompleteRoute {
                    ForEach(legs) { leg in
                        MapPolyline(leg.polyline)
                            .stroke(routeViewModel.savedRoute?.color.swiftUIColor ?? .red, lineWidth: 5)
                    }
                } else if let route = routeViewModel.savedRoute, route.polyline.count >= 2 {
                    MapPolyline(coordinates: route.polyline.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    })
                    .stroke(route.color.swiftUIColor, lineWidth: 5)
                } else {
                    ForEach(legs) { leg in
                        MapPolyline(leg.polyline).stroke(.red, lineWidth: 5)
                    }
                }

                ForEach(waypoints) { waypoint in
                    Annotation("", coordinate: routeViewModel.displayedCoordinate(for: waypoint)) {
                        WaypointMarker(kind: routeViewModel.markerKind(for: waypoint))
                            .onTapGesture { routeViewModel.removeWaypoint(waypoint) }
                    }
                }

                if routeCreationMode == .automatic, let automaticDestination {
                    Marker(automaticDestination.title ?? "Destination", coordinate: automaticDestination.coordinate)
                        .tint(.purple)
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .onTapGesture { screenPoint in
                handleMapTap(at: screenPoint, using: mapProxy)
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isMapExpanded.toggle() }
            } label: {
                Image(systemName: isMapExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel(isMapExpanded ? "Shrink map" : "Expand map")
            .padding(10)
        }
    }

    private func handleMapTap(at screenPoint: CGPoint, using mapProxy: MapProxy) {
        guard let coordinate = mapProxy.convert(screenPoint, from: .local) else { return }
        switch routeCreationMode {
        case .manual:
            routeViewModel.addWaypoint(at: coordinate)
        case .automatic:
            automaticDestination = MapWaypoint(coordinate: coordinate, title: "Destination")
        case .loadPreset:
            break
        }
    }

    private func searchAddresses() async {
        let query = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingAddress else { return }

        isSearchingAddress = true
        addressSearchMessage = nil
        addressResults = []
        defer { isSearchingAddress = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region = visibleRegion ?? cameraPosition.region {
            request.region = region
        } else if let userCoordinate = locationManager.userCoordinate {
            request.region = neighborhoodRegion(center: userCoordinate)
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            addressResults = response.mapItems.prefix(5).map { AddressSearchResult(item: $0) }
            if addressResults.isEmpty {
                addressSearchMessage = "No matching addresses found."
            }
        } catch {
            addressSearchMessage = "Address search failed: \(error.localizedDescription)"
        }
    }

    private func selectAddress(_ result: AddressSearchResult) {
        let coordinate = result.item.placemark.coordinate
        let title = result.item.name ?? result.item.placemark.title
        if routeCreationMode == .automatic {
            automaticDestination = MapWaypoint(coordinate: coordinate, title: title)
        } else {
            routeViewModel.addWaypoint(at: coordinate, title: title)
        }
        cameraPosition = .region(neighborhoodRegion(center: coordinate))
        addressQuery = ""
        addressResults = []
        addressSearchMessage = nil
        isAddressSearchFocused = false
    }

    private func neighborhoodRegion(center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 1_200, longitudinalMeters: 1_200)
    }

    private var routeModePicker: some View {
        Picker("Route setup", selection: $routeCreationMode) {
            ForEach(RouteCreationMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var routeModeControls: some View {
        switch routeCreationMode {
        case .manual:
            addressSearchPanel
        case .automatic:
            VStack(spacing: 8) {
                addressSearchPanel
                automaticRoutePanel
            }
        case .loadPreset:
            presetRoutePanel
        }
    }

    private func routeModePanel(waypoints: [MapWaypoint], waypointListHeight: CGFloat, isCompact: Bool) -> some View {
        VStack(spacing: 8) {
            routeModeControls
            if !isCompact { statusPanel(waypoints: waypoints) }
            waypointPanel(waypoints: waypoints, listHeight: waypointListHeight)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary, lineWidth: 1)
        }
    }

    private var automaticRoutePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let automaticDestination {
                    Text("Destination · \(automaticDestination.title ?? "Selected on map")")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Clear") { self.automaticDestination = nil }
                        .font(.caption)
                } else {
                    Text("Tap on the map or search for destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Stop Interval")
                    .font(.headline)
                Spacer()
                Picker("Stop Interval", selection: $stopIntervalMeters) {
                    Text("200 m").tag(200.0)
                    Text("300 m").tag(300.0)
                    Text("500 m").tag(500.0)
                    Text("1 km").tag(1_000.0)
                    if ![200.0, 300.0, 500.0, 1_000.0].contains(stopIntervalMeters) {
                        Text("Adjusted · \(formattedDistance(stopIntervalMeters))")
                            .tag(stopIntervalMeters)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                Toggle("Express Mode", isOn: $isExpressModeEnabled)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    generateAutomaticRoute()
                } label: {
                    if isGeneratingRoute {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Generate route")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(locationManager.userCoordinate == nil || automaticDestination == nil || isGeneratingRoute)
            }

            if locationManager.userCoordinate == nil {
                Text("Waiting for your current location to use as the start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var presetRoutePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Choose a saved route")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Route Library") { isShowingRouteLibrary = true }
                    .font(.subheadline.weight(.semibold))
            }

            if let presetError {
                Text(presetError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if savedRoutes.isEmpty {
                Text("No saved routes yet. Build a route in Manual or Automatic, then save it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 6) {
                        ForEach(savedRoutes) { route in
                            presetRouteRow(route)
                        }
                    }
                }
                .frame(maxHeight: isMapExpanded ? 88 : 150)

                Button {
                    guard let selectedPresetID,
                          let route = savedRoutes.first(where: { $0.id == selectedPresetID }) else { return }
                    routeViewModel.loadSavedRoute(route)
                } label: {
                    Label("Load Selected Route", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPresetID == nil)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func presetRouteRow(_ route: SavedRoute) -> some View {
        let isSelected = selectedPresetID == route.id
        return Button {
            selectedPresetID = route.id
        } label: {
            HStack(spacing: 10) {
                if route.polyline.count >= 2 {
                    RouteLinePreview(coordinates: route.polyline, color: route.color.swiftUIColor)
                        .frame(width: 74, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(route.color.swiftUIColor.opacity(0.12))
                        .overlay(Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(route.color.swiftUIColor))
                        .frame(width: 74, height: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(route.color.swiftUIColor).frame(width: 9, height: 9)
                        Text("Route \(route.routeNumber.isEmpty ? "—" : route.routeNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(route.color.swiftUIColor) }
            }
            .padding(6)
            .background(isSelected ? route.color.swiftUIColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(route.color.swiftUIColor) : AnyShapeStyle(.quaternary), lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(route.name), route \(route.routeNumber)")
    }

    private func refreshSavedRoutes() {
        do {
            savedRoutes = try SavedRouteStore.loadAll().sorted { $0.savedAt > $1.savedAt }
            presetError = nil
            if !savedRoutes.contains(where: { $0.id == selectedPresetID }) {
                selectedPresetID = savedRoutes.first?.id
            }
        } catch {
            presetError = "Could not load saved routes: \(error.localizedDescription)"
        }
    }

    private func generateAutomaticRoute() {
        guard let origin = locationManager.userCoordinate,
              let destination = automaticDestination else { return }
        isGeneratingRoute = true
        let generationID = UUID()
        automaticGenerationID = generationID
        let requestedInterval = stopIntervalMeters
        let expressMode = isExpressModeEnabled
        automaticRouteTask = Task {
            let effectiveInterval = await routeViewModel.generateAutomaticRoute(
                from: origin,
                to: destination.coordinate,
                destinationTitle: destination.title,
                stopInterval: requestedInterval,
                expressMode: expressMode
            )
            guard automaticGenerationID == generationID else { return }
            if let effectiveInterval {
                stopIntervalMeters = effectiveInterval
            }
            isGeneratingRoute = false
            automaticRouteTask = nil
        }
    }

    /// Moves the camera to the user the first time a location arrives.
    private func centreOnUserOnce(hasFix: Bool) {
        guard hasFix, let coordinate = locationManager.userCoordinate else { return }
        routeViewModel.setDefaultStart(at: coordinate)
        if !hasCentredOnUser {
            hasCentredOnUser = true
            cameraPosition = .region(neighborhoodRegion(center: coordinate))
        }
    }

    // MARK: - Subviews

    private var routeHeader: some View {
        VStack(spacing: 2) {
            Text("Waypoint Navigator")
                .font(.title2.bold())
            Text("Choose or Create a Route to Ride")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let savedRoute = routeViewModel.savedRoute {
                HStack(spacing: 8) {
                    Text(savedRoute.routeNumber)
                        .font(.title3.bold())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(savedRoute.color.swiftUIColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(savedRoute.color.swiftUIColor, lineWidth: 2)
                        }
                    Text(savedRoute.name)
                        .font(.headline)
                }
                .padding(.top, 3)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func statusPanel(waypoints: [MapWaypoint]) -> some View {
        let waypointCount = waypoints.count
        let lastWaypoint = waypoints.last
        return VStack(spacing: 4) {
            Text("Waypoints: \(waypointCount)")
                .font(.headline)

            if waypoints.isEmpty || (waypoints.count == 1 && waypoints[0].title == "Current Location") {
                Text("Tap on the map or search for an address to add waypoints")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
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
    }

    private var addressSearchPanel: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search an address or place", text: $addressQuery)
                    .focused($isAddressSearchFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await searchAddresses() } }

                if isSearchingAddress {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Search") {
                        Task { await searchAddresses() }
                    }
                    .disabled(addressQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let addressSearchMessage {
                Text(addressSearchMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !addressResults.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(addressResults) { result in
                            Button {
                                selectAddress(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.item.name ?? result.item.placemark.title ?? "Address result")
                                        .font(.subheadline.weight(.medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let subtitle = result.item.placemark.title,
                                       subtitle != result.item.name {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if result.id != addressResults.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func waypointPanel(waypoints: [MapWaypoint], listHeight: CGFloat) -> some View {
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
                .frame(height: min(CGFloat(waypoints.count) * 58, listHeight))

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
                        routeNumberInput = routeViewModel.savedRoute?.routeNumber ?? ""
                        routeNameInput = routeViewModel.savedRoute?.name ?? ""
                        if let savedRoute = routeViewModel.savedRoute {
                            selectedRouteColor = savedRoute.color.swiftUIColor
                        }
                        isShowingSaveForm = true
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!routeViewModel.hasCompleteRoute)

                    Button("Clear", role: .destructive) {
                        routeViewModel.resetDraft(defaultStart: locationManager.userCoordinate)
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
    }

    private func waypointRow(_ waypoint: MapWaypoint, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            WaypointMarker(kind: routeViewModel.markerKind(for: waypoint))
                .scaleEffect(0.78)
                .frame(width: 30, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(waypointTitle(at: index, count: count))
                    .font(.subheadline.weight(.medium))
                Text(waypoint.title ?? String(format: "%.5f, %.5f", waypoint.coordinate.latitude, waypoint.coordinate.longitude))
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

    private var saveRouteForm: some View {
        NavigationStack {
            Form {
                Section("Route details") {
                    TextField("Route number", text: $routeNumberInput)
                        .textInputAutocapitalization(.characters)
                    TextField("Route name", text: $routeNameInput)
                        .textInputAutocapitalization(.words)
                    ColorPicker("Route colour", selection: $selectedRouteColor, supportsOpacity: false)
                }

                Section {
                    Text("The saved route includes its ordered stops, route line, leg times, and estimated arrivals.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Save Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingSaveForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        routeViewModel.saveRoute(
                            routeNumber: routeNumberInput,
                            name: routeNameInput,
                            color: savedRouteColor(from: selectedRouteColor)
                        )
                        isShowingSaveForm = false
                    }
                    .disabled(
                        routeNumberInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        routeNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func savedRouteColor(from color: Color) -> SavedRouteColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SavedRouteColor(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
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

private struct AddressSearchResult: Identifiable {
    let id = UUID()
    let item: MKMapItem
}

private enum RouteCreationMode: String, CaseIterable, Identifiable {
    case manual
    case automatic
    case loadPreset

    var id: Self { self }

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .automatic: return "Automatic"
        case .loadPreset: return "Load Preset"
        }
    }
}

#Preview {
    WaypointMapView()
}
