import SwiftUI
import MapKit

struct RouteLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoad: (SavedRoute, Bool) -> Void

    @State private var routes: [SavedRoute] = []
    @State private var loadError: String?
    @State private var deleteError: String?
    @State private var routePendingDeletion: SavedRoute?
    @State private var isConfirmingDelete = false
    @State private var libraryDisplay: LibraryDisplay = .list
    @State private var mapCamera: MapCameraPosition = .automatic
    @State private var selectedMapRouteID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if routes.isEmpty {
                    ContentUnavailableView("No saved routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Routes you save will appear here."))
                } else {
                    VStack(spacing: 0) {
                        Picker("Library display", selection: $libraryDisplay) {
                            Text("List").tag(LibraryDisplay.list)
                            Text("Map").tag(LibraryDisplay.map)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 8)
                        if libraryDisplay == .map {
                            routeMap
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    if let deleteError {
                                        Text(deleteError)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    ForEach(routes) { route in
                                        SavedRouteCard(route: route) {
                                            onLoad(route, false)
                                            dismiss()
                                        } onReverse: {
                                            onLoad(route, true)
                                            dismiss()
                                        } onDelete: {
                                            routePendingDeletion = route
                                            isConfirmingDelete = true
                                        }
                                    }
                                }
                                .padding()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Route Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete Route", isPresented: $isConfirmingDelete, presenting: routePendingDeletion) { route in
                Button("Delete", role: .destructive) { delete(route) }
                Button("Cancel", role: .cancel) { routePendingDeletion = nil }
            } message: { route in
                Text("Delete route \(route.routeNumber), \(route.name)? This cannot be undone.")
            }
            .task { reloadRoutes() }
        }
    }

    private var routeMap: some View {
        Map(position: $mapCamera) {
            ForEach(routes.filter { $0.polyline.count >= 2 }) { route in
                let coordinates = route.polyline.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                MapPolyline(coordinates: coordinates)
                    .stroke(route.color.swiftUIColor, lineWidth: 5)
                if let middle = coordinates.dropFirst(max(0, (coordinates.count - 1) / 2)).first {
                    Annotation(route.routeNumber, coordinate: middle, anchor: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedMapRouteID = selectedMapRouteID == route.id ? nil : route.id
                                }
                            } label: {
                                Text(route.routeNumber.isEmpty ? "—" : route.routeNumber)
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(route.color.swiftUIColor, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white, lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            if selectedMapRouteID == route.id {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(route.name)
                                        .font(.subheadline.bold())
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        Button("Load") {
                                            onLoad(route, false)
                                            dismiss()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        Button("Reverse") {
                                            onLoad(route, true)
                                            dismiss()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                                .padding(9)
                                .frame(maxWidth: 210, alignment: .leading)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(route.color.swiftUIColor, lineWidth: 1.5))
                                .shadow(radius: 4)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mapControls { MapCompass(); MapScaleView() }
        .overlay(alignment: .topLeading) {
            if let deleteError {
                Text(deleteError).font(.caption).foregroundStyle(.red)
                    .padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
            }
        }
    }

    private func reloadRoutes() {
        do {
            routes = SavedRouteStore.sortedByRouteNumber(try SavedRouteStore.loadAll())
        } catch {
            loadError = "Could not read saved routes: \(error.localizedDescription)"
        }
    }

    private func delete(_ route: SavedRoute) {
        do {
            try SavedRouteStore.delete(id: route.id)
            routes.removeAll { $0.id == route.id }
            routePendingDeletion = nil
            deleteError = nil
        } catch {
            deleteError = "Could not delete route: \(error.localizedDescription)"
            routePendingDeletion = nil
        }
    }

}

private enum LibraryDisplay { case list, map }

struct SavedRouteCard: View {
    let route: SavedRoute
    let onLoad: () -> Void
    let onReverse: () -> Void
    let onDelete: () -> Void

    private var totalTravelTime: TimeInterval {
        route.waypoints.compactMap(\.travelTimeFromPrevious).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(route.routeNumber.isEmpty ? "—" : route.routeNumber)
                    .font(.headline.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(route.color.swiftUIColor, lineWidth: 2)
                    }
                Text(route.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete route \(route.routeNumber)")
            }

            if route.polyline.count >= 2 {
                RouteLinePreview(coordinates: route.polyline, color: route.color.swiftUIColor)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Saved route geometry is unavailable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }

            HStack {
                Text("\(route.waypoints.count) waypoints · \(formattedDuration(totalTravelTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Load route", action: onLoad)
                    .buttonStyle(.borderedProminent)
                Button("Load in reverse", action: onReverse)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

struct RouteLinePreview: View {
    let coordinates: [SavedCoordinate]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard coordinates.count > 1 else { return }

            let averageLatitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let longitudeScale = max(cos(averageLatitude * .pi / 180), 0.01)
            let xValues = coordinates.map { $0.longitude * longitudeScale }
            let yValues = coordinates.map(\.latitude)
            let minX = xValues.min() ?? 0
            let maxX = xValues.max() ?? 0
            let minY = yValues.min() ?? 0
            let maxY = yValues.max() ?? 0
            let rangeX = max(maxX - minX, 0.000_001)
            let rangeY = max(maxY - minY, 0.000_001)
            let scale = min((size.width - 20) / rangeX, (size.height - 20) / rangeY)
            let drawnWidth = rangeX * scale
            let drawnHeight = rangeY * scale
            let originX = (size.width - drawnWidth) / 2
            let originY = (size.height - drawnHeight) / 2

            var path = Path()
            for index in coordinates.indices {
                let point = CGPoint(
                    x: originX + (xValues[index] - minX) * scale,
                    y: size.height - originY - (yValues[index] - minY) * scale
                )
                if index == coordinates.startIndex {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .background(Color.secondary.opacity(0.08))
    }
}

extension SavedRouteColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
