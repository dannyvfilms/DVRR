//
//  ContentView.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var plexService: PlexService

    var body: some View {
        Group {
            if plexService.session != nil {
                ChannelsView()
            } else {
                LoginView()
            }
        }
    }
}
#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
        .environmentObject(PlexService())
        .environmentObject(ChannelStore())
}
