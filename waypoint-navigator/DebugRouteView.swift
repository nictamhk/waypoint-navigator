import SwiftUI
import MapKit
import NavigationCore

struct DebugRouteView: View {
    @State private var model = DebugRouteModel()

    var body: some View {
        VStack(spacing: 0) {
            MapReader { proxy in
                Map(position: $model.camera) {
                    if let origin = model.origin {
                        Marker("Origin", coordinate: origin.clCoordinate).tint(.green)
                    }
                    if let destination = model.destination {
                        Marker("Destination", coordinate: destination.clCoordinate).tint(.red)
                    }
                    if let snapshot = model.snapshot {
                        MapPolyline(coordinates: snapshot.geometry.vertices.map(\.clCoordinate))
                            .stroke(.blue, lineWidth: 4)
                        ForEach(model.stopRows) { row in
                            Annotation(row.title, coordinate: row.coordinate.clCoordinate) {
                                Text(row.detail)
                                    .font(.caption2)
                                    .padding(4)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    if let probe = model.probe {
                        Marker("Probe", coordinate: probe.coordinate.clCoordinate).tint(.orange)
                    }
                    if let fix = model.rawFix {
                        Annotation("", coordinate: fix.coordinate.clCoordinate) {
                            Circle().fill(.red).frame(width: 10, height: 10)      // raw GPS fix
                        }
                    }
                    if let snapped = model.latest?.match?.snapped {
                        Annotation("", coordinate: snapped.clCoordinate) {
                            Circle().fill(.green).frame(width: 12, height: 12)    // matched position
                        }
                    }
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        model.handleTap(GeoCoordinate(coordinate))
                    }
                }
            }
            controls
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status).font(.footnote)
                HStack {
                    Picker("Automatic stop interval", selection: $model.automaticStopInterval) {
                        Text("200 m").tag(200.0)
                        Text("300 m").tag(300.0)
                        Text("500 m").tag(500.0)
                        Text("1 km").tag(1000.0)
                    }
                    Button("Build") { Task { await model.build() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canBuild)
                }
                if model.isBuilding { ProgressView() }

                if let snapshot = model.snapshot {
                    if !model.isDriving {
                        Slider(value: $model.probeChainage, in: 0...max(snapshot.geometry.totalLength, 1))
                        if let probe = model.probe {
                            Text(probe.text).font(.footnote.monospacedDigit())
                        }
                    }
                    if !snapshot.warnings.isEmpty {
                        Text("Warning: \(snapshot.warnings.count) leg(s) where MapKit distance and polyline length disagree")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    Divider()
                    driveControls
                }
            }
            .padding()
        }
        .frame(maxHeight: 330)
    }

    private var driveControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drive simulation").font(.headline)
            Toggle("Live GPS (Core Location)", isOn: $model.useLiveGPS).disabled(model.isDriving)
            if !model.useLiveGPS {
                Toggle("Add 5 m GPS jitter", isOn: $model.addJitter).disabled(model.isDriving)
                Toggle("Add a 20 s GPS dropout", isOn: $model.addDropout).disabled(model.isDriving)
                Picker("Replay speed", selection: $model.replaySpeed) {
                    Text("x1").tag(1.0)
                    Text("x5").tag(5.0)
                    Text("x10").tag(10.0)
                    Text("x30").tag(30.0)
                }
                .pickerStyle(.segmented)
                .disabled(model.isDriving)
            }
            Button(model.isDriving ? "Stop" : "Start drive") {
                if model.isDriving { model.stopDrive() } else { model.startDrive() }
            }
            .buttonStyle(.borderedProminent)
            Text(model.driveStatus).font(.footnote.monospacedDigit())
        }
    }
}
