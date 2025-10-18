//
//  ContentView.swift
//  PlexChannelsTV
//
//  Created by Daniel von Seckendorff on 10/17/25.
//

import SwiftUI
import SwiftData
import PlexKit

struct ContentView: View {
    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore

    var body: some View {
        Group {
            if plexService.session != nil {
                MainContentView()
                    .environmentObject(channelStore)
            } else {
                LoginView()
            }
        }
    }
}

private struct MainContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore

    @State private var activeAlert: AlertContent?
    @State private var creatingLibraryKey: String?

    var body: some View {
        NavigationSplitView {
            List {
                channelsSection
                librariesSection
                sampleSection
            }
            .listStyle(.sidebar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out", role: .destructive) {
                        plexService.signOut()
                    }
                }
            }
            .overlay {
                if creatingLibraryKey != nil {
                    ProgressView("Creating Channel…")
                        .progressViewStyle(.circular)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert(item: $activeAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        } detail: {
            if let serverName = plexService.session?.server.name {
                VStack(spacing: 12) {
                    Text(serverName)
                        .font(.title2)
                    Text("Select a channel or library to continue.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Select an item")
            }
        }
    }

    private var channelsSection: some View {
        Section(header: Text("Channels")) {
            if channelStore.channels.isEmpty {
                Text("No channels yet. Select a library to create one.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(channelStore.channels) { channel in
                    ChannelRow(channel: channel)
                }
                .onDelete(perform: deleteChannels)
            }
        }
    }

    private var librariesSection: some View {
        Section(header: Text("Libraries")) {
            ForEach(plexService.session?.libraries ?? [], id: \.uuid) { library in
                Button {
                    createChannel(from: library)
                } label: {
                    libraryRow(for: library)
                }
                .buttonStyle(.plain)
                .focusable(true)
                .disabled(shouldDisable(library: library))
            }
        }
    }

    private var sampleSection: some View {
        Section(header: Text("Sample Data")) {
            ForEach(items) { item in
                NavigationLink {
                    Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                } label: {
                    Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                }
            }
            .onDelete(perform: deleteItems)
        }
    }

    private func libraryRow(for library: PlexLibrary) -> some View {
        HStack(spacing: 16) {
            Image(systemName: iconName(for: library.type))
                .foregroundStyle(.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(library.title ?? "Unknown Library")
                    .font(.headline)
                Text(library.type.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if creatingLibraryKey == library.uuid {
                ProgressView()
                    .progressViewStyle(.circular)
            } else if channelStore.containsChannel(for: library) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func shouldDisable(library: PlexLibrary) -> Bool {
        creatingLibraryKey != nil || channelStore.containsChannel(for: library)
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }

    private func deleteChannels(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                channelStore.removeChannel(channelStore.channels[index])
            }
        }
    }

    private func createChannel(from library: PlexLibrary) {
        guard creatingLibraryKey == nil else { return }
        creatingLibraryKey = library.uuid

        Task { @MainActor in
            defer { creatingLibraryKey = nil }
            do {
                let channel = try await channelStore.createChannel(from: library, using: plexService)
                activeAlert = AlertContent(
                    title: "Channel Created",
                    message: "“\(channel.name)” is ready with \(channel.items.count) item(s)."
                )
            } catch let error as ChannelStore.ChannelCreationError {
                activeAlert = AlertContent(
                    title: "Channel Error",
                    message: error.errorDescription ?? "Unable to create channel."
                )
            } catch {
                activeAlert = AlertContent(
                    title: "Channel Error",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func iconName(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film.fill"
        case .show, .season, .episode:
            return "tv.fill"
        case .artist, .album, .track:
            return "music.note.list"
        case .photo, .picture, .photoAlbum:
            return "photo.fill.on.rectangle.fill"
        case .collection:
            return "square.stack.3d.up.fill"
        default:
            return "play.rectangle.fill"
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.accent)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.headline)

                if let playback = channel.playbackState() {
                    Text("Now playing: \(playback.media.title) • \(formattedOffset(playback.offset)) elapsed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready to play • \(channel.items.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func formattedOffset(_ offset: TimeInterval) -> String {
        let minutes = Int(offset) / 60
        let seconds = Int(offset) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct AlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
        .environmentObject(PlexService())
        .environmentObject(ChannelStore())
}
