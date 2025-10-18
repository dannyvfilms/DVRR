//
//  ChannelsView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI

struct ChannelsView: View {
    @EnvironmentObject private var channelStore: ChannelStore
    @EnvironmentObject private var plexService: PlexService

    private enum Destination: Hashable {
        case addChannel
        case channel(Channel)
    }

    @State private var path: [Destination] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                channelsSection
                addChannelSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Channels")
            .background(Color.clear)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out", role: .destructive) {
                        plexService.signOut()
                    }
                }
            }
        }
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .addChannel:
                AddChannelView(
                    onChannelCreated: { channel in
                        path = [.channel(channel)]
                    }
                )
            case .channel(let channel):
                ChannelPlayerView(channel: channel)
            }
        }
    }

    private var channelsSection: some View {
        Section {
            if channelStore.channels.isEmpty {
                emptyStateRow
            } else {
                ForEach(channelStore.channels) { channel in
                    NavigationLink(value: Destination.channel(channel)) {
                        ChannelRow(channel: channel)
                    }
                    .focusable(true)
                }
                .onDelete { indexSet in
                    withAnimation {
                        let channelsToRemove = indexSet.map { channelStore.channels[$0] }
                        channelsToRemove.forEach(channelStore.removeChannel)
                    }
                }
            }
        } header: {
            Text("Your Channels")
        }
    }

    private var addChannelSection: some View {
        Section {
            NavigationLink(value: Destination.addChannel) {
                Label("Add Channel", systemImage: "plus.circle.fill")
                    .font(.headline)
            }
            .focusable(true)
        }
    }

    private var emptyStateRow: some View {
        VStack(spacing: 8) {
            Text("No channels yet")
                .font(.headline)
            Text("Add a channel to start watching your Plex libraries.")
                .font(.callout)
                .foregroundStyle(.secondary)
            NavigationLink(value: Destination.addChannel) {
                Text("Add Channel")
                    .font(.body)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .focusable(true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
        .listRowBackground(Color.clear)
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.circle.fill")
                .foregroundStyle(.accent)
                .font(.title2)

            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name)
                    .font(.headline)

                if let nowPlaying = channel.nowPlayingTitle() {
                    Text("Now playing: \(nowPlaying)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(channel.items.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}
