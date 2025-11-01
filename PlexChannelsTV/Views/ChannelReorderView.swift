//
//  ChannelReorderView.swift
//  PlexChannelsTV
//
//  Created by Codex on 01/13/25.
//

import SwiftUI
import PlexKit
import os.log

struct ChannelReorderView: View {
    @EnvironmentObject private var channelStore: ChannelStore
    @EnvironmentObject private var plexService: PlexService
    @Environment(\.dismiss) private var dismiss
    
    @State private var orderedChannels: [Channel] = []
    @State private var pickedUpIndex: Int?
    @State private var hasUnsavedChanges = false
    @State private var showCancelConfirm = false
    @FocusState private var focusedIndex: Int?
    
    private var originalOrder: [UUID] {
        channelStore.channels.map { $0.id }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(Array(orderedChannels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(channel, at: index)
                                .focused($focusedIndex, equals: index)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Header with Done button
                VStack {
                    HStack {
                        Text("Reorder Channels")
                            .font(.title.bold())
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        Button("Done") {
                            saveOrder()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 80)
                    .padding(.top, 40)
                    
                    Spacer()
                }
            }
            .onAppear {
                orderedChannels = channelStore.channels
                // Set initial focus
                if !orderedChannels.isEmpty {
                    focusedIndex = 0
                }
            }
            .onChange(of: channelStore.channels) { oldChannels, newChannels in
                // Handle deleted channels
                let currentIDs = Set(orderedChannels.map { $0.id })
                let storeIDs = Set(newChannels.map { $0.id })
                let deletedIDs = currentIDs.subtracting(storeIDs)
                
                if !deletedIDs.isEmpty {
                    orderedChannels.removeAll { deletedIDs.contains($0.id) }
                }
                
                // Add any new channels that appeared
                let newChannelsSet = Set(newChannels.map { $0.id })
                let existingIDs = Set(orderedChannels.map { $0.id })
                let addedIDs = newChannelsSet.subtracting(existingIDs)
                
                if !addedIDs.isEmpty {
                    let addedChannels = newChannels.filter { addedIDs.contains($0.id) }
                    orderedChannels.append(contentsOf: addedChannels)
                }
            }
            .confirmationDialog(
                "Discard Changes?",
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You have unsaved changes. Are you sure you want to discard them?")
            }
            .onExitCommand {
                if hasUnsavedChanges {
                    showCancelConfirm = true
                } else {
                    dismiss()
                }
            }
            .focusable()
            .onMoveCommand { direction in
                if let pickedUp = pickedUpIndex {
                    handleMoveCommand(direction, from: pickedUp)
                }
            }
        }
    }
    
    @ViewBuilder
    private func channelRow(_ channel: Channel, at index: Int) -> some View {
        let isPickedUp = pickedUpIndex == index
        let isFocused = focusedIndex == index
        
        HStack(spacing: 24) {
            // Thumbnail
            if let firstItem = channel.items.first,
               let posterURL = plexService.posterArtworkURL(for: firstItem, width: 240, height: 360) {
                CachedAsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholderThumbnail
                    case .empty:
                        ProgressView()
                    }
                }
                .frame(width: 120, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                placeholderThumbnail
            }
            
            // Title and metadata
            VStack(alignment: .leading, spacing: 8) {
                Text(channel.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                
                // Media type badge
                HStack(spacing: 8) {
                    Image(systemName: mediaTypeIcon(for: channel.libraryType))
                        .font(.caption)
                    Text(channel.libraryType.displayName)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            
            Spacer()
            
            // Grab handle (only when focused)
            if isFocused {
                Image(systemName: isPickedUp ? "hand.raised.fill" : "line.3.horizontal")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isFocused ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
        )
        .scaleEffect(isPickedUp ? 1.05 : (isFocused ? 1.02 : 1.0))
        .shadow(
            color: isFocused ? .accentColor.opacity(0.3) : .clear,
            radius: isPickedUp ? 20 : 12
        )
        .onPlayPauseCommand {
            if isFocused {
                if let pickedUp = pickedUpIndex {
                    if pickedUp == index {
                        // Drop it
                        pickedUpIndex = nil
                    } else {
                        // Pick up the focused one
                        pickedUpIndex = index
                    }
                } else {
                    // Pick it up
                    pickedUpIndex = index
                }
            }
        }
    }
    
    private var placeholderThumbnail: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.gray.opacity(0.3))
            .frame(width: 120, height: 180)
            .overlay {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.5))
            }
    }
    
    private func mediaTypeIcon(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film"
        case .show, .episode:
            return "tv"
        default:
            return "play.rectangle"
        }
    }
    
    private func handleMoveCommand(_ direction: MoveCommandDirection, from index: Int) {
        switch direction {
        case .up:
            if index > 0 {
                let newIndex = index - 1
                orderedChannels.move(fromOffsets: IndexSet(integer: index), toOffset: newIndex)
                pickedUpIndex = newIndex
                focusedIndex = newIndex
                hasUnsavedChanges = true
            }
        case .down:
            if index < orderedChannels.count - 1 {
                let newIndex = index + 1
                orderedChannels.move(fromOffsets: IndexSet(integer: index), toOffset: newIndex + 1)
                pickedUpIndex = newIndex
                focusedIndex = newIndex
                hasUnsavedChanges = true
            }
        @unknown default:
            break
        }
    }
    
    private func saveOrder() {
        let newOrder = orderedChannels.map { $0.id }
        channelStore.setChannelOrder(newOrder)
        AppLoggers.channel.info("event=channel.reorder.save count=\(newOrder.count)")
        dismiss()
    }
}

extension PlexMediaType {
    var displayName: String {
        switch self {
        case .movie:
            return "Movie"
        case .show:
            return "TV Show"
        case .episode:
            return "Episode"
        default:
            return "Media"
        }
    }
}

