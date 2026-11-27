//
//  ContentView.swift
//  waypoint-navigator
//
//  Created by 譚德朗 on 21/11/2026.
//

import SwiftUI

/*
struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
*/


struct ContentView: View {
    @State private var routeViewModel = RouteViewModel()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                WaypointMapView(routeViewModel: routeViewModel)
            }
            .tabItem { Label("Map", systemImage: "map") }
            .tag(0)

            NavigationStack {
                RouteLibraryView { id in
                    routeViewModel.loadPreset(id)
                    selectedTab = 0
                }
                    .navigationTitle("Load Preset")
            }
            .tabItem { Label("Load Preset", systemImage: "tray.full") }
            .tag(1)
        }
    }
}

#Preview {
    ContentView()
}
