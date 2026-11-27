import SwiftUI

struct RouteLibraryView: View {
    var onLoad: (UUID) -> Void = { _ in }
    @State private var routes: [RouteDatabase.LibraryRoute] = []

    var body: some View {
        List {
            if routes.isEmpty {
                ContentUnavailableView("No saved routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            } else {
                ForEach(routes) { route in
                    RouteLibraryRow(route: route, onLoad: { onLoad(route.id) }) { reload() }
                }
            }
        }
        .navigationTitle("Route Library")
        .onAppear(perform: reload)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh", systemImage: "arrow.clockwise", action: reload) } }
    }

    private func reload() { routes = RouteDatabase.shared.libraryRoutes() }
}

private struct RouteLibraryRow: View {
    let route: RouteDatabase.LibraryRoute
    let onLoad: () -> Void
    let onSaved: () -> Void
    @State private var number: String
    @State private var name: String
    @State private var message: String?

    init(route: RouteDatabase.LibraryRoute, onLoad: @escaping () -> Void, onSaved: @escaping () -> Void) {
        self.route = route
        self.onLoad = onLoad
        self.onSaved = onSaved
        _number = State(initialValue: route.number)
        _name = State(initialValue: route.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Route number", text: $number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                TextField("Route name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("\(route.waypointCount) waypoints").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Load") { onLoad() }.buttonStyle(.bordered)
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        do {
            try RouteDatabase.shared.updateRouteDetails(id: route.id, number: number, name: name)
            message = nil
            onSaved()
        } catch {
            message = error.localizedDescription
        }
    }
}
