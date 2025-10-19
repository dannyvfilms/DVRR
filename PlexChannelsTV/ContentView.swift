//
//  ContentView.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var authState: AuthState

    var body: some View {
        Group {
            if authState.session != nil {
                ChannelsView()
            } else {
                LinkLoginView()
            }
        }
    }
}
#Preview {
    let plexService = PlexService()
    let linkService = PlexLinkService(
        clientIdentifier: plexService.clientIdentifier,
        product: "PlexChannelsTV",
        version: "1.0",
        device: "Apple TV",
        platform: "tvOS",
        deviceName: "Apple TV"
    )
    let authState = AuthState(plexService: plexService, linkService: linkService)

    return ContentView()
        .modelContainer(for: Item.self, inMemory: true)
        .environmentObject(plexService)
        .environmentObject(ChannelStore())
        .environmentObject(authState)
}
