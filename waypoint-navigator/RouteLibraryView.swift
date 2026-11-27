import SwiftUI

struct RouteLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoad: (SavedRoute) -> Void

    @State private var routes: [SavedRoute] = []
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView("Library unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if routes.isEmpty {
                    ContentUnavailableView("No saved routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", description: Text("Routes you save will appear here."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(routes) { route in
                                SavedRouteCard(route: route) {
                                    onLoad(route)
                                    dismiss()
                                }
                            }
                        }
                        .padding()
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
            .task { reloadRoutes() }
        }
    }

    private func reloadRoutes() {
        do {
            routes = try SavedRouteStore.loadAll().sorted { $0.savedAt > $1.savedAt }
        } catch {
            loadError = "Could not read saved routes: \(error.localizedDescription)"
        }
    }
}

struct SavedRouteCard: View {
    let route: SavedRoute
    let onLoad: () -> Void

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
