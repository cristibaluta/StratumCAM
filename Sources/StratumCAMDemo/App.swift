//
//  StratumCAMDemoApp.swift
//  StratumCAM
//
//  Created by Cristian Baluta on 11.09.2026.
//

import SwiftUI
import StratumCAM

@main
struct StratumCAMDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("StratumCAM Demo App")
                .font(.title)
            Button("Run Demo Action") {
                // Call into StratumCAM here
            }
        }
        .frame(width: 400, height: 300)
        .padding()
    }
}
