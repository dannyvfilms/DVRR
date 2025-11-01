//
//  ChannelsView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI
import PlexKit
import os.log

struct ChannelsView: View {
    @EnvironmentObject private var channelStore: ChannelStore
    @EnvironmentObject private var authState: AuthState
    @EnvironmentObject private var plexService: PlexService
    @StateObject private var coordinator = ChannelsCoordinator()

    private enum Destination: Hashable {
        case quickPlay(LibraryPreviewItem)
    }

    enum FocusTarget: Hashable {
        case now(Channel.ID)
        case upNext(Channel.ID, String)
    }

    @State private var path: [Destination] = []
    @State private var showChannelBuilder = false
    @State private var editingChannel: Channel? = nil
    @State private var showReorderChannels = false
    @State private var hasAutoPresentedBuilder = false
    @State private var previewItems: [LibraryPreviewItem] = []
    @State private var isLoadingPreviews = false
    @State private var quickPlayError: String?
    @State private var pendingFocusRestore: FocusTarget?

    @FocusState private var headerAddFocused: Bool
    @FocusState private var focusedCard: FocusTarget?
    @State private var lastFocusedCard: FocusTarget?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 32) {
                header
                    .focusSectionIfAvailable()

                if channelStore.channels.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                        .focusSectionIfAvailable()
                } else {
                    channelList
                        .focusSectionIfAvailable()
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 40)
            .background(Color.black.opacity(0.001))
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .quickPlay(let item):
                    QuickPlayView(item: item)
                        .environmentObject(plexService)
                }
            }
        }
        .fullScreenCover(isPresented: $showChannelBuilder, onDismiss: {
            editingChannel = nil
            if channelStore.channels.isEmpty {
                headerAddFocused = true
            }
        }) {
            ChannelBuilderFlowView(
                plexService: plexService,
                channelStore: channelStore,
                libraries: plexService.session?.libraries ?? [],
                existingChannel: editingChannel,
                onComplete: { channel in
                    showChannelBuilder = false
                    editingChannel = nil
                    hasAutoPresentedBuilder = true
                    focusChannel(channel)
                },
                onCancel: {
                    showChannelBuilder = false
                    editingChannel = nil
                    if channelStore.channels.isEmpty {
                        headerAddFocused = true
                    }
                }
            )
        }
        .fullScreenCover(item: $coordinator.playbackRequest, onDismiss: {
            AppLoggers.playback.info("event=player.cover.dismissed")
            coordinator.dismissPlayback()
            restoreFocusAfterPlayback()
        }) { request in
            ChannelPlayerView(
                request: request,
                onExit: {
                    coordinator.dismissPlayback()
                }
            )
            .environmentObject(plexService)
            .environmentObject(channelStore)
            .onAppear {
                AppLoggers.playback.info(
                    "event=player.cover.shown channelID=\(request.channelID.uuidString, privacy: .public) channelName=\(request.channelName, privacy: .public) itemID=\(request.itemID, privacy: .public)"
                )
            }
        }
        .fullScreenCover(isPresented: $showReorderChannels) {
            ChannelReorderView()
                .environmentObject(channelStore)
                .environmentObject(plexService)
        }
        .onAppear {
            evaluateInitialState()
            loadPreviewItemsIfNeeded()
        }
        .onChange(of: channelStore.channels.count) { _, _ in
            evaluateInitialState()
        }
        .onChange(of: authState.session) { _, _ in
            loadPreviewItemsIfNeeded()
        }
        .alert("Playback Error", isPresented: Binding(
            get: { quickPlayError != nil },
            set: { if !$0 { quickPlayError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(quickPlayError ?? "An unknown error occurred")
        }
        .onChange(of: focusedCard) { _, newValue in
            lastFocusedCard = newValue
            guard case let .now(channelID) = newValue else { return }
            guard let channel = channelStore.channels.first(where: { $0.id == channelID }) else { return }
            AppLoggers.channel.info(
                "event=channel.focus channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public)"
            )
        }
    }
}

// MARK: - Components

private extension ChannelsView {
    var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(statusLine)
                    .font(.headline)
                if let subtext = substatusLine {
                    Text(subtext)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                showChannelBuilder = true
            } label: {
                Label("Add Channel", systemImage: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .focused($headerAddFocused)

            // #if DEBUG
            // if let firstChannel = channelStore.channels.first {
            //     Button {
            //         pendingFocusRestore = .now(firstChannel.id)
            //         _ = coordinator.presentForce(channel: firstChannel)
            //     } label: {
            //         Label("Force Play Now", systemImage: "play.rectangle.fill")
            //             .font(.title3)
            //     }
            //     .buttonStyle(.borderless)
            // }
            // #endif
        }
    }

    var emptyState: some View {
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
                                PosterButton(item: item) {
                                    playPreviewItem(item)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else if isLoadingPreviews {
                ProgressView("Loading your libraries…")
            }
        }
    }

    var channelList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 48) {
                ForEach(channelStore.channels) { channel in
                    ChannelRowView(
                        channel: channel,
                        focusBinding: $focusedCard,
                        nowFocusID: .now(channel.id),
                        upNextFocusID: { item in
                            .upNext(channel.id, item.id)
                        },
                        onPrimaryPlay: { channel in
                            handlePlayNow(channel)
                        },
                        onMenuAction: { channel, action in
                            handleMenuAction(channel: channel, action: action)
                        },
                        onPlayItem: { channel, media in
                            handlePlayItem(channel: channel, media: media)
                        },
                        onItemMenuAction: { channel, media, action in
                            handleItemMenuAction(channel: channel, media: media, action: action)
                        }
                    )
                    .environmentObject(plexService)
                    .focusSectionIfAvailable()
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Playback Handlers

private extension ChannelsView {
    func handlePlayNow(_ channel: Channel) {
        AppLoggers.channel.info(
            "event=channel.tap.received handler=handlePlayNow channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public)"
        )
        
        let timestamp = Date()
        guard let position = channel.playbackPosition(at: timestamp) else {
            AppLoggers.channel.error(
                "event=channel.tap status=error reason=\"no_schedule\" channelID=\(channel.id.uuidString, privacy: .public)"
            )
            return
        }

        let media = position.media
        let offset = position.offset
        let nowTitle = media.episodeTitle
        let seasonNumber = media.metadata?.seasonNumber ?? 0
        let episodeNumber = media.metadata?.episodeNumber ?? 0

        AppLoggers.channel.info(
            "event=channel.tap.prepare channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(media.id, privacy: .public) itemTitle=\(nowTitle, privacy: .public) s=\(seasonNumber) e=\(episodeNumber) offsetSec=\(Int(offset))"
        )

        pendingFocusRestore = .now(channel.id)
        let request = coordinator.presentNow(channel: channel, at: timestamp, source: .tap)
        
        AppLoggers.channel.info(
            "event=channel.tap.completed channelID=\(channel.id.uuidString, privacy: .public) requestCreated=\(request != nil)"
        )
    }

    func handleMenuAction(channel: Channel, action: ChannelRowView.MenuAction) {
        let timestamp = Date()
        switch action {
        case .edit:
            AppLoggers.channel.info(
                "event=channel.longPress action=edit channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public)"
            )
            editingChannel = channel
            showChannelBuilder = true
        case .reorder:
            AppLoggers.channel.info(
                "event=channel.longPress action=reorder"
            )
            showReorderChannels = true
        case .startNow:
            AppLoggers.channel.info(
                "event=channel.longPress action=startNow channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public)"
            )
            pendingFocusRestore = .now(channel.id)
            _ = coordinator.presentNow(channel: channel, at: timestamp, source: .tap)
        case .startBeginning:
            guard let current = channel.nowPlaying(at: timestamp) else {
                AppLoggers.channel.error(
                    "event=channel.longPress action=startBeginning status=error reason=\"no_schedule\" channelID=\(channel.id.uuidString, privacy: .public)"
                )
                return
            }

            AppLoggers.channel.info(
                "event=channel.longPress action=startBeginning channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(current.id, privacy: .public)"
            )

            pendingFocusRestore = .now(channel.id)
            _ = coordinator.presentItem(
                channel: channel,
                itemID: current.id,
                offset: 0,
                source: .beginning,
                at: timestamp
            )
        case .delete:
            AppLoggers.channel.info(
                "event=channel.longPress action=delete channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public)"
            )

            if coordinator.playbackRequest?.channelID == channel.id {
                coordinator.dismissPlayback()
            }

            channelStore.removeChannel(channel)
            pendingFocusRestore = nil
            focusedCard = nil

            if channelStore.channels.isEmpty {
                headerAddFocused = true
            }

            AppLoggers.channel.info(
                "event=channel.remove.ok channelID=\(channel.id.uuidString, privacy: .public) remaining=\(channelStore.channels.count)"
            )
        }
    }

    func handlePlayItem(channel: Channel, media: Channel.Media) {
        let itemTitle = media.episodeTitle
        let seasonNumber = media.metadata?.seasonNumber ?? 0
        let episodeNumber = media.metadata?.episodeNumber ?? 0
        AppLoggers.channel.info(
            "event=channel.next.tap.received handler=handlePlayItem channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(media.id, privacy: .public) itemTitle=\(itemTitle, privacy: .public) s=\(seasonNumber) e=\(episodeNumber)"
        )

        pendingFocusRestore = .now(channel.id)
        let request = coordinator.presentItem(
            channel: channel,
            itemID: media.id,
            offset: 0,
            source: .upnext,
            at: Date()
        )
        
        AppLoggers.channel.info(
            "event=channel.next.tap.completed channelID=\(channel.id.uuidString, privacy: .public) itemID=\(media.id, privacy: .public) requestCreated=\(request != nil)"
        )
    }

    func handleItemMenuAction(
        channel: Channel,
        media: Channel.Media,
        action: ChannelRowView.MenuAction
    ) {
        switch action {
        case .edit:
            // Edit action not available from up next items, redirect to channel edit
            handleMenuAction(channel: channel, action: .edit)
        case .startNow:
            AppLoggers.channel.info(
                "event=channel.longPress action=startNow channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(media.id, privacy: .public)"
            )
            pendingFocusRestore = .now(channel.id)
            _ = coordinator.presentItem(
                channel: channel,
                itemID: media.id,
                offset: 0,
                source: .upnext,
                at: Date()
            )
        case .startBeginning:
            AppLoggers.channel.info(
                "event=channel.longPress action=startBeginning channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(media.id, privacy: .public)"
            )
            pendingFocusRestore = .now(channel.id)
            _ = coordinator.presentItem(
                channel: channel,
                itemID: media.id,
                offset: 0,
                source: .beginning,
                at: Date()
            )
        case .delete:
            AppLoggers.channel.info(
                "event=channel.longPress action=delete source=upnext channelID=\(channel.id.uuidString, privacy: .public) channelName=\(channel.name, privacy: .public) itemID=\(media.id, privacy: .public)"
            )
            handleMenuAction(channel: channel, action: .delete)
        case .reorder:
            AppLoggers.channel.info(
                "event=channel.longPress action=reorder source=upnext"
            )
            handleMenuAction(channel: channel, action: .reorder)
        case .edit:
            // Edit from up next redirects to channel edit
            handleMenuAction(channel: channel, action: .edit)
        }
    }
}

// MARK: - Helpers

private extension ChannelsView {
    func evaluateInitialState() {
        if channelStore.channels.isEmpty {
            if !hasAutoPresentedBuilder && !showChannelBuilder {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showChannelBuilder = true
                }
                hasAutoPresentedBuilder = true
            }
            headerAddFocused = true
            focusedCard = nil
        } else {
            headerAddFocused = false
            if let first = channelStore.channels.first {
                focusedCard = .now(first.id)
            }
        }
    }

    func loadPreviewItemsIfNeeded() {
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
                        media: media,
                        streamURL: nil,
                        streamKind: nil
                    )
                }

                await MainActor.run {
                    self.previewItems = previews
                    AppLoggers.channel.info(
                        "event=channel.previewLoaded libraryID=\(targetLibrary.key, privacy: .public) itemCount=\(previews.count)"
                    )
                }
            } catch {
                AppLoggers.channel.error("event=channel.previewFailed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func choosePreviewLibrary(from libraries: [PlexLibrary]) -> PlexLibrary? {
        let preferredTypes: Set<PlexMediaType> = [.movie, .show, .episode]
        if let match = libraries.first(where: { preferredTypes.contains($0.type) }) {
            return match
        }
        return libraries.first
    }

    func playPreviewItem(_ item: LibraryPreviewItem) {
        if let descriptor = plexService.streamDescriptor(for: item.media) ??
            plexService.streamDescriptor(for: item.media, preferTranscode: true) {
            let enriched = item.withStreamDescriptor(descriptor)
            AppLoggers.playback.info(
                "event=quickPlay.prepared itemID=\(item.id, privacy: .public) title=\(item.title, privacy: .public) mode=\(descriptor.kind.rawValue, privacy: .public)"
            )
            path.append(.quickPlay(enriched))
        } else {
            let message = PlexService.PlaybackError.noStreamURL.errorDescription ?? "Unable to start playback."
            AppLoggers.playback.error(
                "event=quickPlay.unavailable itemID=\(item.id, privacy: .public) title=\(item.title, privacy: .public) reason=\"\(message, privacy: .public)\""
            )
            quickPlayError = message
        }
    }

    func focusChannel(_ channel: Channel) {
        DispatchQueue.main.async {
            focusedCard = .now(channel.id)
        }
    }

    func restoreFocusAfterPlayback() {
        let target = pendingFocusRestore ?? lastFocusedCard ?? channelStore.channels.first.map { FocusTarget.now($0.id) }
        pendingFocusRestore = nil
        DispatchQueue.main.async {
            focusedCard = target
        }
    }

    var statusLine: String {
        guard let sessionInfo = authState.session else {
            return "Not linked"
        }
        return "Linked to \(sessionInfo.accountName) · \(sessionInfo.serverName)"
    }

    var substatusLine: String? {
        guard let sessionInfo = authState.session else { return nil }
        return "\(sessionInfo.libraryCount) libraries available"
    }
}

// MARK: - Preview Items

private struct PosterButton: View {
    let item: LibraryPreviewItem
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                poster
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
    }

    private var poster: some View {
        CachedAsyncImage(url: item.thumbURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .failure:
                placeholder
            case .empty:
                ProgressView()
                    .frame(width: 200, height: 300)
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.gray.opacity(0.4))
            .frame(width: 200, height: 300)
            .overlay(
                Image(systemName: "film")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.7))
            )
    }
}

struct LibraryPreviewItem: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbURL: URL?
    let media: Channel.Media
    let streamURL: URL?
    let streamKind: PlexService.StreamKind?

    func withStreamDescriptor(_ descriptor: PlexService.StreamDescriptor) -> LibraryPreviewItem {
        LibraryPreviewItem(
            id: id,
            title: title,
            thumbURL: thumbURL,
            media: media,
            streamURL: descriptor.url,
            streamKind: descriptor.kind
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LibraryPreviewItem, rhs: LibraryPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}
