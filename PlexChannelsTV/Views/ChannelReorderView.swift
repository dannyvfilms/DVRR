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
            VStack(spacing: 0) {
                // Header with Done button
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
                .padding(.bottom, 24)
                
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(Array(orderedChannels.enumerated()), id: \.element.id) { index, channel in
                            channelRow(channel, at: index)
                                .focused($focusedIndex, equals: index)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.bottom, 40)
                }
                .scrollClipDisabled(true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
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
            .onMoveCommand { direction in
                if let pickedUp = pickedUpIndex {
                    AppLoggers.channel.info("event=reorder.move direction=\(direction == .up ? "up" : "down") from=\(pickedUp)")
                    handleMoveCommand(direction, from: pickedUp)
                }
            }
        }
    }
    
    @ViewBuilder
    private func channelRow(_ channel: Channel, at index: Int) -> some View {
        let isPickedUp = pickedUpIndex == index
        let isFocused = focusedIndex == index
        
        Button {
            // Primary action - no-op, just for focus
        } label: {
            HStack(spacing: 20) {
                // Title and metadata
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.name)
                        .font(.headline)
                    
                    // Media type badge
                    HStack(spacing: 6) {
                        Image(systemName: mediaTypeIcon(for: channel.libraryType))
                            .font(.caption2)
                        Text(channel.libraryType.displayName)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                
                Spacer()
                
                // Grab handle (only when focused)
                if isFocused {
                    Image(systemName: isPickedUp ? "hand.raised.fill" : "line.3.horizontal")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isFocused ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 12, style: .continuous))
        .buttonStyle(.plain)
        .focused($focusedIndex, equals: index)
        .onPlayPauseCommand {
            if isFocused {
                if let pickedUp = pickedUpIndex {
                    if pickedUp == index {
                        // Drop it
                        pickedUpIndex = nil
                        AppLoggers.channel.info("event=reorder.drop index=\(index)")
                    } else {
                        // Pick up the focused one (drop the old one first)
                        pickedUpIndex = index
                        AppLoggers.channel.info("event=reorder.pickup index=\(index) previous=\(pickedUp)")
                    }
                } else {
                    // Pick it up
                    pickedUpIndex = index
                    AppLoggers.channel.info("event=reorder.pickup index=\(index)")
                }
            }
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
        guard index >= 0 && index < orderedChannels.count else { return }
        
        switch direction {
        case .up:
            if index > 0 {
                let newIndex = index - 1
                // Swap elements
                orderedChannels.swapAt(index, newIndex)
                pickedUpIndex = newIndex
                focusedIndex = newIndex
                hasUnsavedChanges = true
                AppLoggers.channel.info("event=reorder.move.up from=\(index) to=\(newIndex)")
            }
        case .down:
            if index < orderedChannels.count - 1 {
                let newIndex = index + 1
                // Swap elements
                orderedChannels.swapAt(index, newIndex)
                pickedUpIndex = newIndex
                focusedIndex = newIndex
                hasUnsavedChanges = true
                AppLoggers.channel.info("event=reorder.move.down from=\(index) to=\(newIndex)")
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


