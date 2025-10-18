//
//  PlexChannelsTVApp.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import SwiftUI
import SwiftData

@main
struct PlexChannelsTVApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    @StateObject private var plexService = PlexService()
    @StateObject private var channelStore = ChannelStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(plexService)
                .environmentObject(channelStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
