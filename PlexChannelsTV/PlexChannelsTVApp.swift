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
    @StateObject private var plexService: PlexService
    @StateObject private var authState: AuthState
    @StateObject private var channelStore: ChannelStore

    init() {
        let plexService = PlexService()
        let channelStore = ChannelStore()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let linkService = PlexLinkService(
            clientIdentifier: plexService.clientIdentifier,
            product: "DVRR TV",
            version: version,
            device: "Apple TV",
            platform: "tvOS",
            deviceName: "Apple TV"
        )
        let channelSeeder = ChannelSeeder(plexService: plexService, channelStore: channelStore)

        _plexService = StateObject(wrappedValue: plexService)
        _channelStore = StateObject(wrappedValue: channelStore)
        _authState = StateObject(wrappedValue: AuthState(
            plexService: plexService,
            linkService: linkService,
            channelSeeder: channelSeeder
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(plexService)
                .environmentObject(authState)
                .environmentObject(channelStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
