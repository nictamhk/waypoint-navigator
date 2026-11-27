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
    @State private var isConfirmingRouteOverwrite = false
    @State private var pendingRouteOverwriteNumber = ""
    @State private var routeNumberDigits = ""
    @State private var routeNumberPrefix = ""
    @State private var routeNumberSuffix = ""
    @State private var includesRoutePrefix = false
    @State private var includesRouteSuffix = false
    @State private var routeNameInput = ""
    @State private var selectedRouteColor: Color = .blue
    @State private var routeCreationMode: RouteCreationMode = .manual
    @State private var isShowingRouteLibrary = false
    @State private var savedRoutes: [SavedRoute] = []
    @State private var selectedPresetID: UUID?
    @State private var presetError: String?
    @State private var presetSearchText = ""
    @State private var automaticDestination: MapWaypoint?
    @State private var isResolvingAutomaticDestinationName = false
    @State private var stopIntervalMeters = 1_000.0
    @State private var stopIntervalInput = "1000"
    @State private var isExpressModeEnabled = false
    @State private var isShowingExpressHelp = false
    @State private var isGeneratingRoute = false
    @State private var hasGeneratedAutomaticRoute = false
    @State private var areAutomaticControlsExpanded = true
    @State private var automaticRouteTask: Task<Void, Never>?
    @State private var automaticGenerationID = UUID()
    @State private var addressQuery = ""
    @State private var addressResults: [AddressSearchResult] = []
    @State private var isSearchingAddress = false
    @State private var activeAddressSearch: MKLocalSearch?
    @State private var addressSearchGeneration = UUID()
    @State private var addressSearchMessage: String?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var isMapExpanded = false
    @FocusState private var isAddressSearchFocused: Bool
    @FocusState private var isRouteNumberFocused: Bool
    @FocusState private var focusedWaypointNameID: UUID?
    @State private var editingWaypointID: UUID?

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Read the model once per redraw so SwiftUI reliably refreshes the map content.
        let waypoints = routeViewModel.waypoints
        let legs = routeViewModel.legs

        GeometryReader { geometry in
            let mapHeight: CGFloat = {
                if isMapExpanded {
                    return min(max(geometry.size.height * (routeCreationMode == .automatic ? 0.28 : 0.40), 210), 520)
                }
                if routeCreationMode == .automatic {
                    return min(max(geometry.size.height * 0.23, 150), 230)
                }
                return min(max(geometry.size.height * 0.29, 180), 280)
            }()
            VStack(spacing: 10) {
                routeHeader

                routeModePicker

                if focusedWaypointNameID == nil && (routeCreationMode != .loadPreset || routeViewModel.savedRoute != nil) {
                    mapPreview(waypoints: waypoints, legs: legs)
                        .frame(height: mapHeight)
                }

                routeModePanel(
                    waypoints: waypoints,
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
        .fullScreenCover(isPresented: $isShowingRouteLibrary, onDismiss: { refreshSavedRoutes() }) {
            RouteLibraryView { route in
                routeViewModel.loadSavedRoute(route)
                selectedPresetID = route.id
                automaticDestination = nil
                focusMap(on: route)
            }
        }
        .onChange(of: routeCreationMode) { _, mode in
            isMapExpanded = false
            automaticGenerationID = UUID()
            automaticRouteTask?.cancel()
            automaticRouteTask = nil
            isGeneratingRoute = false
            hasGeneratedAutomaticRoute = false
            areAutomaticControlsExpanded = true
            routeViewModel.resetDraft(defaultStart: locationManager.userCoordinate)
            automaticDestination = nil
            isResolvingAutomaticDestinationName = false
            addressQuery = ""
            activeAddressSearch?.cancel()
            addressSearchGeneration = UUID()
            isSearchingAddress = false
            addressResults = []
            addressSearchMessage = nil
            selectedPresetID = nil
            presetSearchText = ""
            isEditingWaypoints = false
            editingWaypointID = nil
            focusedWaypointNameID = nil
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
            let labeledWaypointIDs = nonOverlappingLabelIDs(for: waypoints, using: mapProxy)
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
                    let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) ?? 0
                    Annotation("", coordinate: routeViewModel.displayedCoordinate(for: waypoint), anchor: .leading) {
                        HStack(spacing: 5) {
                            WaypointMarker(kind: routeViewModel.markerKind(for: waypoint))
                            if labeledWaypointIDs.contains(waypoint.id) {
                                Text(waypointMapName(waypoint, index: index, count: waypoints.count))
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
                            }
                        }
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
        .overlay(alignment: .bottomTrailing) {
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
            addManualWaypoint(at: coordinate)
        case .automatic:
            let destination = MapWaypoint(coordinate: coordinate, title: "Destination")
            automaticDestination = destination
            isResolvingAutomaticDestinationName = true
            Task {
                let resolvedName = await routeViewModel.suggestedStopName(at: coordinate) ?? "Destination"
                guard automaticDestination?.id == destination.id else { return }
                automaticDestination = MapWaypoint(id: destination.id, coordinate: coordinate, title: resolvedName)
                isResolvingAutomaticDestinationName = false
            }
        case .loadPreset:
            break
        }
    }

    private func searchAddresses(query rawQuery: String? = nil) async {
        let query = (rawQuery ?? addressQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let region = visibleRegion ?? cameraPosition.region {
            request.region = region
        } else if let userCoordinate = locationManager.userCoordinate {
            request.region = neighborhoodRegion(center: userCoordinate)
        }

        let generation = UUID()
        addressSearchGeneration = generation
        activeAddressSearch?.cancel()
        let search = MKLocalSearch(request: request)
        activeAddressSearch = search
        isSearchingAddress = true
        addressSearchMessage = nil

        do {
            let response = try await search.start()
            guard addressSearchGeneration == generation,
                  addressQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            addressResults = response.mapItems.prefix(5).map { AddressSearchResult(item: $0) }
            if addressResults.isEmpty {
                addressSearchMessage = "No matching addresses found."
            }
        } catch {
            guard addressSearchGeneration == generation else { return }
            if !(error is CancellationError) {
                addressSearchMessage = "Address search failed: \(error.localizedDescription)"
            }
        }
        if addressSearchGeneration == generation { isSearchingAddress = false }
    }

    private func submitAddressSearch() {
        let query = addressQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearchingAddress else { return }
        addressResults = []
        addressSearchMessage = nil
        isAddressSearchFocused = false
        Task { await searchAddresses(query: query) }
    }

    private func selectAddress(_ result: AddressSearchResult) {
        let coordinate = result.item.placemark.coordinate
        let title = result.item.name ?? result.item.placemark.title
        if routeCreationMode == .automatic {
            automaticDestination = MapWaypoint(coordinate: coordinate, title: title)
            isResolvingAutomaticDestinationName = false
        } else {
            addManualWaypoint(at: coordinate, title: title)
        }
        cameraPosition = .region(neighborhoodRegion(center: coordinate))
        addressQuery = ""
        activeAddressSearch?.cancel()
        addressSearchGeneration = UUID()
        addressResults = []
        addressSearchMessage = nil
        isAddressSearchFocused = false
    }

    private func neighborhoodRegion(center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, latitudinalMeters: 1_200, longitudinalMeters: 1_200)
    }

    private func addManualWaypoint(at coordinate: CLLocationCoordinate2D, title: String? = nil) {
        let fallback = "Stop \(routeViewModel.waypoints.count)"
        let id = routeViewModel.addWaypoint(at: coordinate, title: title ?? fallback)
        Task { await routeViewModel.resolveWaypointName(id: id, fallback: fallback) }
    }

    private func waypointMapName(_ waypoint: MapWaypoint, index: Int, count: Int) -> String {
        if let title = waypoint.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return waypointTitle(at: index, count: count)
    }

    private func nonOverlappingLabelIDs(for waypoints: [MapWaypoint], using mapProxy: MapProxy) -> Set<UUID> {
        let projected = waypoints.compactMap { waypoint -> (MapWaypoint, CGPoint, String)? in
            guard let point = mapProxy.convert(routeViewModel.displayedCoordinate(for: waypoint), to: .local) else { return nil }
            let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) ?? 0
            return (waypoint, point, waypointMapName(waypoint, index: index, count: waypoints.count))
        }
        let markerFrames = Dictionary(uniqueKeysWithValues: projected.map { item in
            (item.0.id, CGRect(x: item.1.x - 17, y: item.1.y - 17, width: 34, height: 34))
        })
        let priorityOrdered = projected.sorted { lhs, rhs in
            let lhsIsEndpoint = lhs.0.title == "Current Location" || lhs.0.title == "Destination"
            let rhsIsEndpoint = rhs.0.title == "Current Location" || rhs.0.title == "Destination"
            return lhsIsEndpoint && !rhsIsEndpoint
        }
        var acceptedFrames: [CGRect] = []
        var acceptedIDs: Set<UUID> = []
        for (waypoint, point, name) in priorityOrdered {
            let labelWidth = min(max(CGFloat(name.count) * 6.5 + 14, 52), 150)
            let labelFrame = CGRect(x: point.x + 20, y: point.y - 14, width: labelWidth, height: 28)
                .insetBy(dx: -5, dy: -4)
            let overlapsMarker = markerFrames.contains { id, frame in
                id != waypoint.id && frame.intersects(labelFrame)
            }
            guard !overlapsMarker, !acceptedFrames.contains(where: { $0.intersects(labelFrame) }) else { continue }
            acceptedFrames.append(labelFrame)
            acceptedIDs.insert(waypoint.id)
        }
        return acceptedIDs
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
            addressSearchPanel(isAutomatic: false)
        case .automatic:
            VStack(spacing: 8) {
                addressSearchPanel(isAutomatic: true)
                    .zIndex(2)
                automaticRoutePanel
                    .zIndex(1)
            }
        case .loadPreset:
            presetRoutePanel
        }
    }

    private func routeModePanel(waypoints: [MapWaypoint], isCompact: Bool) -> some View {
        GeometryReader { geometry in
            let reservedHeight: CGFloat = {
                if routeCreationMode == .automatic && hasGeneratedAutomaticRoute {
                    return areAutomaticControlsExpanded ? 400 : 130
                }
                if routeCreationMode == .manual { return 240 }
                return 400
            }()
            VStack(spacing: 8) {
                if routeCreationMode == .automatic && hasGeneratedAutomaticRoute && focusedWaypointNameID == nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            areAutomaticControlsExpanded.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Route settings")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: areAutomaticControlsExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }

                if focusedWaypointNameID == nil && (routeCreationMode != .automatic || !hasGeneratedAutomaticRoute || areAutomaticControlsExpanded) {
                    routeModeControls
                        .zIndex(addressResults.isEmpty ? 0 : 20)
                }
                if focusedWaypointNameID == nil && !isCompact && (routeCreationMode != .automatic || !hasGeneratedAutomaticRoute) {
                    statusPanel(waypoints: waypoints)
                }
                if routeCreationMode != .automatic && (routeCreationMode != .loadPreset || routeViewModel.savedRoute != nil) || hasGeneratedAutomaticRoute {
                    let availableListHeight = isCompact ? 110 : max(110, geometry.size.height - reservedHeight)
                    waypointPanel(waypoints: waypoints, listHeight: availableListHeight)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .zIndex(2)
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
                    Button("Clear") {
                        self.automaticDestination = nil
                        isResolvingAutomaticDestinationName = false
                    }
                        .font(.caption)
                } else {
                    Text("Tap on the map or search for destination")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Stop Interval")
                .font(.headline)
            HStack(spacing: 8) {
                ForEach([200.0, 300.0, 500.0, 1_000.0], id: \.self) { interval in
                    Button {
                        stopIntervalMeters = interval
                        stopIntervalInput = formattedStopInterval(interval)
                    } label: {
                        Text(interval == 1_000 ? "1 000 m" : "\(Int(interval)) m")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Double(stopIntervalInput) == interval ? .accentColor : .secondary)
                }
            }
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { min(max(stopIntervalMeters, 200), 1_000) },
                    set: { value in
                        stopIntervalMeters = value
                        stopIntervalInput = formattedStopInterval(value)
                    }
                ), in: 200...1_000, step: 10)
                TextField("m", text: $stopIntervalInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: stopIntervalInput) { _, value in
                        if let interval = Double(value), interval > 0 {
                            stopIntervalMeters = interval
                        }
                    }
                Text("m")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Toggle("Express Mode", isOn: $isExpressModeEnabled)
                    .toggleStyle(.switch)
                Button { isShowingExpressHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Express Mode help")
                Spacer()
            }

            Button(action: generateAutomaticRoute) {
                HStack {
                    Spacer()
                    Text("Generate route")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(locationManager.userCoordinate == nil || automaticDestination == nil || isResolvingAutomaticDestinationName || isGeneratingRoute || (Double(stopIntervalInput) ?? 0) <= 0)

            if isGeneratingRoute {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Generating waypoint list…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if locationManager.userCoordinate == nil {
                Text("Waiting for your current location to use as the start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Express Mode", isPresented: $isShowingExpressHelp) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Route through highways are preferred when Express Mode is on")
        }
        .padding(isMapExpanded ? 6 : 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func formattedStopInterval(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search route name or number", text: $presetSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !presetSearchText.isEmpty {
                        Button {
                            presetSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Clear route search")
                    }
                }
                .padding(9)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                let normalizedSearch = presetSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let filteredRoutes = savedRoutes.filter { route in
                    normalizedSearch.isEmpty || route.name.localizedCaseInsensitiveContains(normalizedSearch) ||
                    route.routeNumber.localizedCaseInsensitiveContains(normalizedSearch)
                }

                if filteredRoutes.isEmpty {
                    Text("No routes match your search.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView(.vertical) {
                        VStack(spacing: 6) {
                            ForEach(filteredRoutes) { route in
                                presetRouteRow(route)
                            }
                        }
                    }
                    .frame(maxHeight: routeViewModel.savedRoute == nil ? 360 : (isMapExpanded ? 88 : 150))

                    Button {
                        guard let selectedPresetID,
                              let route = savedRoutes.first(where: { $0.id == selectedPresetID }) else { return }
                        routeViewModel.loadSavedRoute(route)
                        focusMap(on: route)
                    } label: {
                        Label("Load Selected Route", systemImage: "arrow.down.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedPresetID == nil)
                }
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
                Text(route.routeNumber.isEmpty ? "—" : route.routeNumber)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(route.color.swiftUIColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(route.color.swiftUIColor, lineWidth: 2))
                    .frame(minWidth: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(route.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(route.color.swiftUIColor) }
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

    private func focusMap(on route: SavedRoute) {
        let coordinates = route.polyline.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let routeCoordinates = coordinates.count >= 2
            ? coordinates
            : route.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        guard !routeCoordinates.isEmpty else { return }

        var bounds = MKMapRect.null
        for coordinate in routeCoordinates {
            let point = MKMapPoint(coordinate)
            bounds = bounds.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1)))
        }

        let horizontalPadding = max(bounds.width * 0.15, 4_000)
        let verticalPadding = max(bounds.height * 0.15, 4_000)
        cameraPosition = .rect(bounds.insetBy(dx: -horizontalPadding, dy: -verticalPadding))
    }

    private func refreshSavedRoutes() {
        do {
            savedRoutes = SavedRouteStore.sortedByRouteNumber(try SavedRouteStore.loadAll())
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
              let destination = automaticDestination,
              let requestedInterval = Double(stopIntervalInput), requestedInterval > 0 else { return }
        isGeneratingRoute = true
        let generationID = UUID()
        automaticGenerationID = generationID
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
                stopIntervalInput = formattedStopInterval(effectiveInterval)
                hasGeneratedAutomaticRoute = true
                areAutomaticControlsExpanded = false
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
        return VStack(spacing: 4) {
            if routeCreationMode == .manual && (waypoints.isEmpty || (waypoints.count == 1 && waypoints[0].title == "Current Location")) {
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

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func addressSearchPanel(isAutomatic: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search an address or place", text: $addressQuery)
                    .focused($isAddressSearchFocused)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(isAutomatic ? .body : .subheadline)
                    .submitLabel(.search)
                    .onSubmit { submitAddressSearch() }
                    .onChange(of: addressQuery) { _, _ in
                        activeAddressSearch?.cancel()
                        addressSearchGeneration = UUID()
                        addressResults = []
                        addressSearchMessage = nil
                    }

                if isSearchingAddress {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Search") {
                        submitAddressSearch()
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

            ForEach(addressResults) { result in
                Button {
                    selectAddress(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.item.name ?? result.item.placemark.title ?? "Address result")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let subtitle = result.item.placemark.title, subtitle != result.item.name {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .padding(isAutomatic && !isMapExpanded ? 14 : 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func waypointPanel(waypoints: [MapWaypoint], listHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !waypoints.isEmpty {
                HStack {
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

                ScrollViewReader { scrollProxy in
                    List {
                        ForEach(Array(waypoints.enumerated()), id: \.element.id) { index, waypoint in
                            waypointRow(waypoint, index: index, count: waypoints.count)
                                .id(waypoint.id)
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
                    .frame(height: max(0, listHeight))
                    .onChange(of: focusedWaypointNameID) { _, id in
                        guard let id else { return }
                        withAnimation { scrollProxy.scrollTo(id, anchor: .top) }
                    }
                }

                HStack(spacing: 12) {
                    if !routeViewModel.hasCompleteRoute && routeViewModel.isCalculating {
                        ProgressView().controlSize(.small)
                        Text("Estimating…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        let routeNumber = routeViewModel.savedRoute?.routeNumber ?? suggestedRouteNumber()
                        configureRouteNumberFields(from: routeNumber)
                        routeNameInput = routeViewModel.savedRoute?.name ?? suggestedRouteName(number: routeNumber)
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
                        hasGeneratedAutomaticRoute = false
                        editingWaypointID = nil
                        focusedWaypointNameID = nil
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
                if editingWaypointID == waypoint.id {
                    TextField("Stop name", text: Binding(
                        get: { waypoint.title ?? waypointTitle(at: index, count: count) },
                        set: { routeViewModel.renameWaypoint(id: waypoint.id, title: $0) }
                    ))
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .focused($focusedWaypointNameID, equals: waypoint.id)
                    .submitLabel(.done)
                    .onSubmit {
                        editingWaypointID = nil
                        focusedWaypointNameID = nil
                    }
                } else {
                    Text(waypoint.title ?? waypointTitle(at: index, count: count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                if editingWaypointID == waypoint.id {
                    editingWaypointID = nil
                    focusedWaypointNameID = nil
                } else {
                    isMapExpanded = false
                    editingWaypointID = waypoint.id
                    focusedWaypointNameID = waypoint.id
                }
            } label: {
                Image(systemName: editingWaypointID == waypoint.id ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(editingWaypointID == waypoint.id ? "Finish editing stop name" : "Edit stop name")

            VStack(alignment: .trailing, spacing: 2) {
                Text(index == 0 ? "Start" : routeViewModel.estimatedLegTime(at: index).map { "Leg · \(formattedDuration($0))" } ?? "Leg · pending")
                    .font(.subheadline)
                Text("ETA · \(routeViewModel.estimatedArrival(at: index)?.formatted(date: .omitted, time: .shortened) ?? "pending")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { focusMap(on: waypoint) }
    }

    private func focusMap(on waypoint: MapWaypoint) {
        let coordinate = routeViewModel.displayedCoordinate(for: waypoint)
        cameraPosition = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700))
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
                    TextField("Route number", text: $routeNumberDigits)
                        .keyboardType(.numberPad)
                        .focused($isRouteNumberFocused)
                        .onChange(of: routeNumberDigits) { _, value in
                            let digitsOnly = String(value.filter(\.isNumber))
                            if digitsOnly != value { routeNumberDigits = digitsOnly }
                        }

                    Toggle("Add alphabet prefix", isOn: $includesRoutePrefix)
                    if includesRoutePrefix {
                        TextField("Prefix", text: $routeNumberPrefix)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: routeNumberPrefix) { _, value in
                                let lettersOnly = String(value.filter(\.isLetter)).uppercased()
                                if lettersOnly != value { routeNumberPrefix = lettersOnly }
                            }
                    }

                    Toggle("Add alphabet suffix", isOn: $includesRouteSuffix)
                    if includesRouteSuffix {
                        TextField("Suffix", text: $routeNumberSuffix)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .onChange(of: routeNumberSuffix) { _, value in
                                let lettersOnly = String(value.filter(\.isLetter)).uppercased()
                                if lettersOnly != value { routeNumberSuffix = lettersOnly }
                            }
                    }

                    LabeledContent("Complete route number", value: completeRouteNumber.isEmpty ? "—" : completeRouteNumber)
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
                    Button("Save") { saveRouteWithOverwriteCheck() }
                    .disabled(
                        routeNumberDigits.isEmpty ||
                        routeNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isRouteNumberFocused = false }
                }
            }
        }
        .presentationDetents([.medium])
        .alert("Overwrite saved route?", isPresented: $isConfirmingRouteOverwrite) {
            Button("Cancel", role: .cancel) { }
            Button("Overwrite", role: .destructive) {
                persistRoute()
            }
        } message: {
            Text("Route number \(pendingRouteOverwriteNumber) is already in your library. Saving will replace that route.")
        }
    }

    private func suggestedRouteNumber() -> String {
        let routes = (try? SavedRouteStore.loadAll()) ?? []
        let usedNumbers = Set(routes.map(\.routeNumber))
        var nextNumber = (routes.compactMap { Int(String($0.routeNumber.filter(\.isNumber))) }.max() ?? 0) + 1
        while usedNumbers.contains(String(nextNumber)) { nextNumber += 1 }
        return String(nextNumber)
    }

    private var completeRouteNumber: String {
        let prefix = includesRoutePrefix ? String(routeNumberPrefix.filter(\.isLetter)).uppercased() : ""
        let digits = String(routeNumberDigits.filter(\.isNumber))
        let suffix = includesRouteSuffix ? String(routeNumberSuffix.filter(\.isLetter)).uppercased() : ""
        return prefix + digits + suffix
    }

    private func saveRouteWithOverwriteCheck() {
        pendingRouteOverwriteNumber = completeRouteNumber
        let duplicateExists = ((try? SavedRouteStore.loadAll()) ?? []).contains {
            $0.routeNumber.caseInsensitiveCompare(completeRouteNumber) == .orderedSame && $0.id != routeViewModel.savedRoute?.id
        }
        if duplicateExists { isConfirmingRouteOverwrite = true }
        else { persistRoute() }
    }

    private func persistRoute() {
        routeViewModel.saveRoute(routeNumber: completeRouteNumber, name: routeNameInput, color: savedRouteColor(from: selectedRouteColor))
        isShowingSaveForm = false
    }

    private func configureRouteNumberFields(from fullNumber: String) {
        let characters = Array(fullNumber)
        let digitPositions = characters.indices.filter { characters[$0].isNumber }
        routeNumberDigits = String(characters.filter(\.isNumber))
        if let firstDigit = digitPositions.first, let lastDigit = digitPositions.last {
            routeNumberPrefix = String(characters[..<firstDigit].filter(\.isLetter)).uppercased()
            routeNumberSuffix = String(characters[(lastDigit + 1)...].filter(\.isLetter)).uppercased()
        } else {
            routeNumberPrefix = ""
            routeNumberSuffix = ""
        }
        includesRoutePrefix = !routeNumberPrefix.isEmpty
        includesRouteSuffix = !routeNumberSuffix.isEmpty
    }

    private func suggestedRouteName(number: String) -> String {
        if routeCreationMode == .automatic,
           let destination = automaticDestination?.title,
           !destination.isEmpty,
           destination != "Destination" {
            return "Route \(number) to \(destination)"
        }
        return "Route \(number)"
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
