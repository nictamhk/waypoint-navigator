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
    var body: some View {
        WaypointMapView()
    }
}

#Preview {
    ContentView()
}
