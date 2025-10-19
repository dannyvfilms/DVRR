//
//  ChannelsView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI
import AVKit
import PlexKit

struct ChannelsView: View {
    @EnvironmentObject private var channelStore: ChannelStore
    @EnvironmentObject private var authState: AuthState
    @EnvironmentObject private var plexService: PlexService

    private enum Destination: Hashable {
        case channel(Channel)
        case quickPlay(LibraryPreviewItem)
    }

    @State private var path: [Destination] = []
    @State private var channelPendingDeletion: Channel?
    @State private var showLibraryPicker = false
    @State private var wizardLibrary: PlexLibrary?
    @State private var previewItems: [LibraryPreviewItem] = []
    @State private var isLoadingPreviews = false
    @State private var hasAutoPresentedPicker = false

    @FocusState private var headerAddFocused: Bool
    @FocusState private var focusedChannelID: Channel.ID?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 32) {
                header

                if channelStore.channels.isEmpty {
                    emptyState
                } else {
                    channelList
                }

                Spacer()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
            .background(Color.black.opacity(0.001))
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .channel(let channel):
                    ChannelPlayerView(channel: channel)
                        .environmentObject(plexService)
                case .quickPlay(let item):
                    QuickPlayView(item: item)
                        .environmentObject(plexService)
                }
            }
        }
        .sheet(isPresented: $showLibraryPicker, onDismiss: {
            if channelStore.channels.isEmpty {
                headerAddFocused = true
            }
        }) {
            LibraryPickerView(
                libraries: plexService.session?.libraries ?? [],
                onSelect: { library in
                    if let existing = channelStore.channel(for: library) {
                        showLibraryPicker = false
                        focusChannel(existing)
                    } else {
                        wizardLibrary = library
                        showLibraryPicker = false
                    }
                },
                onCancel: {
                    showLibraryPicker = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { wizardLibrary != nil },
            set: { if !$0 { wizardLibrary = nil } }
        )) {
            if let library = wizardLibrary {
                ChannelWizardView(
                    library: library,
                    onComplete: { channel in
                        wizardLibrary = nil
                        hasAutoPresentedPicker = true
                        focusChannel(channel)
                    },
                    onCancel: {
                        wizardLibrary = nil
                        if channelStore.channels.isEmpty {
                            headerAddFocused = true
                        }
                    }
                )
                .environmentObject(plexService)
                .environmentObject(channelStore)
            }
        }
        .confirmationDialog(
            "Remove Channel?",
            isPresented: Binding(
                get: { channelPendingDeletion != nil },
                set: { if !$0 { channelPendingDeletion = nil } }
            ),
            presenting: channelPendingDeletion
        ) { pending in
            Button("Delete “\(pending.name)”", role: .destructive) {
                withAnimation {
                    channelStore.removeChannel(pending)
                }
                channelPendingDeletion = nil
                if channelStore.channels.isEmpty {
                    headerAddFocused = true
                }
            }
        } message: { pending in
            Text("This will remove “\(pending.name)” from your channel lineup. You can recreate it later from the Add Channel screen.")
        }
        .onAppear {
            evaluateInitialState()
            loadPreviewItemsIfNeeded()
        }
        .onChange(of: channelStore.channels.count) { _ in
            evaluateInitialState()
        }
        .onChange(of: authState.session) { _ in
            loadPreviewItemsIfNeeded()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusLine)
                    .font(.headline)
                if let subtext = substatusLine {
                    Text(subtext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showLibraryPicker = true
            } label: {
                Label("Add Channel", systemImage: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .focused($headerAddFocused)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Create your first channel to start watching your Plex libraries as live TV.")
                .font(.title3)
                .foregroundStyle(.secondary)

            if !previewItems.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("From your libraries")
                        .font(.headline)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 24) {
                            ForEach(previewItems) { item in
                                Button {
                                    path.append(.quickPlay(item))
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        AsyncImage(url: item.thumbURL) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: 200, height: 300)
                                                    .cornerRadius(12)
                                            case .failure:
                                                placeholderPoster
                                            case .empty:
                                                ProgressView()
                                                    .frame(width: 200, height: 300)
                                            @unknown default:
                                                placeholderPoster
                                            }
                                        }
                                        Text(item.title)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .frame(width: 200)
                                }
                                .buttonStyle(.plain)
                                .focusable(true)
                            }
                        }
                    }
                }
            } else if isLoadingPreviews {
                ProgressView("Loading your libraries…")
            }
        }
    }

    private var channelList: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(channelStore.channels) { channel in
                Button {
                    path.append(.channel(channel))
                } label: {
                    ChannelRowView(channel: channel) {
                        channelPendingDeletion = channel
                    }
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focused($focusedChannelID, equals: channel.id)
            }
        }
    }

    private func evaluateInitialState() {
        if channelStore.channels.isEmpty {
            if !hasAutoPresentedPicker && !showLibraryPicker && wizardLibrary == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showLibraryPicker = true
                }
                hasAutoPresentedPicker = true
            }
            headerAddFocused = true
            focusedChannelID = nil
        } else {
            headerAddFocused = false
            if let first = channelStore.channels.first {
                focusedChannelID = first.id
            }
        }
    }

    private func loadPreviewItemsIfNeeded() {
        guard previewItems.isEmpty, !isLoadingPreviews else { return }
        guard let libraries = plexService.session?.libraries else { return }

        isLoadingPreviews = true
        Task {
            defer { isLoadingPreviews = false }

            let targetLibrary = choosePreviewLibrary(from: libraries)
            guard let targetLibrary else { return }

            do {
                let items = try await plexService.fetchLibraryItems(for: targetLibrary, limit: 12)
                let previews = items.compactMap { item -> LibraryPreviewItem? in
                    guard let media = Channel.Media.from(item) else { return nil }
                    let thumbURL = item.thumb.flatMap { plexService.buildImageURL(from: $0, width: 300) }
                    return LibraryPreviewItem(
                        id: item.ratingKey,
                        title: item.title ?? "Untitled",
                        thumbURL: thumbURL,
                        media: media
                    )
                }

                await MainActor.run {
                    self.previewItems = previews
                    print("[ChannelsView] Loaded \(previews.count) preview items from \(targetLibrary.title ?? "library")")
                }
            } catch {
                print("[ChannelsView] Failed to load preview items: \(error)")
            }
        }
    }

    private func choosePreviewLibrary(from libraries: [PlexLibrary]) -> PlexLibrary? {
        let ranked = libraries.filter { lib in
            lib.type == .movie || lib.type == .show || lib.type == .episode
        }.sorted { lhs, rhs in
            (lhs.childCount ?? 0) > (rhs.childCount ?? 0)
        }
        return ranked.first ?? libraries.first
    }

    private func focusChannel(_ channel: Channel) {
        DispatchQueue.main.async {
            focusedChannelID = channel.id
        }
    }

    private var statusLine: String {
        guard let sessionInfo = authState.session else {
            return "Not linked"
        }
        return "Linked to \(sessionInfo.accountName) · \(sessionInfo.serverName)"
    }

    private var substatusLine: String? {
        guard let sessionInfo = authState.session else { return nil }
        return "\(sessionInfo.libraryCount) libraries available"
    }

    private var placeholderPoster: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.4))
            .frame(width: 200, height: 300)
            .cornerRadius(12)
            .overlay(
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.7))
            )
    }
}

private struct ChannelRowView: View {
    let channel: Channel
    var onDelete: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)

            HStack(spacing: 24) {
                Image(systemName: "play.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 48))

                TimelineView(.periodic(from: .init(), by: 30)) { context in
                    let now = context.date
                    VStack(alignment: .leading, spacing: 6) {
                        Text(channel.name)
                            .font(.title3)
                            .bold()

                        if let playback = channel.playbackState(at: now),
                           let remaining = channel.timeRemaining(at: now) {
                            Text("Now: \(playback.media.title) · \(formatted(minutes: remaining)) left")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        } else {
                            Text("Now: Schedule pending…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let next = channel.nextUp(after: now) {
                            Text("Next: \(next.title)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(height: 140)
    }

    private func formatted(minutes interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        return "\(minutes) min"
    }
}

struct LibraryPreviewItem: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbURL: URL?
    let media: Channel.Media
}
