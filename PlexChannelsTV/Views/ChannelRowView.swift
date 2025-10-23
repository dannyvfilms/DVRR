//
//  ChannelRowView.swift
//  PlexChannelsTV
//
//  Created by Codex on 11/02/25.
//

import SwiftUI
import UIKit

struct ChannelRowView: View {
    enum MenuAction {
        case startNow
        case startBeginning
        case delete
    }

    private struct Snapshot {
        struct Entry: Hashable, Identifiable {
            let index: Int
            let media: Channel.Media

            var id: String { media.id }
        }

        let now: Entry
        let offset: TimeInterval
        let remaining: TimeInterval
        let upcoming: [Entry]
        let timestamp: Date
    }

    private enum MenuTarget: Equatable {
        case now
        case upNext(Channel.Media)
    }

    let channel: Channel
    let focusBinding: FocusState<ChannelsView.FocusTarget?>.Binding
    let nowFocusID: ChannelsView.FocusTarget
    let upNextFocusID: (Channel.Media) -> ChannelsView.FocusTarget
    let onPrimaryPlay: (Channel) -> Void
    let onMenuAction: (Channel, MenuAction) -> Void
    let onPlayItem: (Channel, Channel.Media) -> Void
    let onItemMenuAction: (Channel, Channel.Media, MenuAction) -> Void

    @EnvironmentObject private var plexService: PlexService
    @State private var menuTarget: MenuTarget?
    @State private var prefetchedURLs: Set<URL> = []

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let snapshot = makeSnapshot(at: context.date)

            HStack(alignment: .top, spacing: 36) {
                nowColumn(for: snapshot)
                upNextColumn(for: snapshot)
            }
            .padding(.vertical, 20)
            .background(prefetchTrigger(for: snapshot))
        }
        .focusSectionIfAvailable()
        .confirmationDialog(
            "",
            isPresented: Binding(
                get: { menuTarget != nil },
                set: { if !$0 { menuTarget = nil } }
            ),
            titleVisibility: .hidden
        ) {
            Button("Start Now") {
                AppLoggers.channel.info(
                    "event=channel.menu.action action=startNow target=\(String(describing: menuTarget), privacy: .public)"
                )
                handleMenuSelection(.startNow)
            }
            Button("Start From Beginning") {
                AppLoggers.channel.info(
                    "event=channel.menu.action action=startBeginning target=\(String(describing: menuTarget), privacy: .public)"
                )
                handleMenuSelection(.startBeginning)
            }
            Button("Delete Channel", role: .destructive) {
                AppLoggers.channel.info(
                    "event=channel.menu.action action=delete target=\(String(describing: menuTarget), privacy: .public)"
                )
                handleMenuSelection(.delete)
            }
            Button("Cancel", role: .cancel) {
                AppLoggers.channel.info("event=channel.menu.action action=cancel")
                menuTarget = nil
            }
        }
    }
}

// MARK: - Layout

private extension ChannelRowView {
    private func nowColumn(for snapshot: Snapshot?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(channel.name)
                .font(.headline)
                .foregroundStyle(.secondary)
            
            nowCard(for: snapshot)
            nowDetails(for: snapshot)
        }
    }

    private func nowCard(for snapshot: Snapshot?) -> some View {
        let cardSize = CGSize(width: 560, height: 315)
        
        return Button {
            AppLoggers.channel.info(
                "event=channel.tap.action channelID=\(channel.id.uuidString, privacy: .public) button=now"
            )
            onPrimaryPlay(channel)
        } label: {
            ZStack {
                // Background artwork
                if let snapshot,
                   let url = plexService.backgroundArtworkURL(for: snapshot.now.media, width: 1280, height: 720, blur: 0) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure, .empty:
                            Color.gray.opacity(0.3)
                        }
                    }
                } else {
                    Color.gray.opacity(0.3)
                }
                
                LinearGradient(
                    colors: [Color.black.opacity(0.4), Color.clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
                
                // Logo artwork or text fallback
                VStack {
                    Spacer()
                    
                    if let snapshot,
                       let logoURL = plexService.logoArtworkURL(for: snapshot.now.media, width: 800, height: 300) {
                        CachedAsyncImage(url: logoURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: cardSize.width * 0.6, maxHeight: cardSize.height * 0.33)
                                    .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 4)
                            case .failure:
                                Text(snapshot.now.media.seriesTitle)
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                    .shadow(radius: 4)
                            case .empty:
                                // Show nothing while loading - prevents text flashing before logo loads
                                Color.clear
                                    .frame(height: 60)
                            }
                    }
                } else {
                    Text(snapshot?.now.media.seriesTitle ?? "Now Playing")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .shadow(radius: 4)
                }
            }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .buttonStyle(.plain)
        .focused(focusBinding, equals: nowFocusID)
        .onPlayPauseCommand {
            AppLoggers.channel.info(
                "event=channel.playPause channelID=\(channel.id.uuidString, privacy: .public) button=now"
            )
            menuTarget = .now
        }
    }

    private func nowDetails(for snapshot: Snapshot?) -> some View {
        let title = snapshot?.now.media.seriesTitle ?? "Schedule pending…"
        let subtitle: String = {
            guard let snapshot else { return "Schedule pending" }
            var components: [String] = []
            if let label = snapshot.now.media.seasonEpisodeLabel {
                components.append(label)
            }
            components.append("\(formatTime(snapshot.remaining)) left")
            return components.joined(separator: " · ")
        }()

        return VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func upNextColumn(for snapshot: Snapshot?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next")
                .font(.headline)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(snapshot?.upcoming ?? []) { entry in
                        upNextCard(for: entry.media)
                            .focused(focusBinding, equals: upNextFocusID(entry.media))
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 350)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func upNextCard(for media: Channel.Media) -> some View {
        let width: CGFloat = 180
        let height: CGFloat = 270
        
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                AppLoggers.channel.info(
                    "event=channel.tap.action channelID=\(channel.id.uuidString, privacy: .public) button=upNext itemID=\(media.id, privacy: .public)"
                )
                onPlayItem(channel, media)
            } label: {
                if let url = plexService.posterArtworkURL(for: media, width: 360, height: 540) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            Color.gray.opacity(0.3)
                        case .empty:
                            ProgressView()
                        }
                    }
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .buttonStyle(.plain)
            .onPlayPauseCommand {
                AppLoggers.channel.info(
                    "event=channel.playPause channelID=\(channel.id.uuidString, privacy: .public) button=upNext itemID=\(media.id, privacy: .public)"
                )
                menuTarget = .upNext(media)
            }
            
            Text(media.seriesTitle)
                .font(.caption)
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
            
            if let label = media.seasonEpisodeLabel {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
    }
}

// MARK: - Artwork Helpers

private extension ChannelRowView {
    @ViewBuilder
    private func nowArtwork(for snapshot: Snapshot?) -> some View {
        if let snapshot,
           let url = plexService.backgroundArtworkURL(for: snapshot.now.media, width: 1280, height: 720, blur: 0) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    fallbackArtwork()
                case .empty:
                    fallbackArtwork(loading: true)
                }
            }
        } else {
            fallbackArtwork()
        }
    }

    @ViewBuilder
    private func posterArtwork(for media: Channel.Media, width: CGFloat, height: CGFloat) -> some View {
        if let url = plexService.posterArtworkURL(for: media, width: Int(width * 2), height: Int(height * 2)) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                case .failure:
                    fallbackPoster(width: width, height: height)
                case .empty:
                    ProgressView()
                        .frame(width: width, height: height)
                }
            }
        } else {
            fallbackPoster(width: width, height: height)
        }
    }

    private func fallbackArtwork(loading: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color.gray.opacity(0.4))
            .overlay {
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: "play.circle")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
    }

    private func fallbackPoster(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.gray.opacity(0.35))
            .frame(width: width, height: height)
            .overlay(
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.7))
            )
    }
}

// MARK: - Prefetching

private extension ChannelRowView {
    @ViewBuilder
    private func prefetchTrigger(for snapshot: Snapshot?) -> some View {
        if let snapshot {
            Color.clear
                .allowsHitTesting(false)
                .id(snapshot.now.media.id)
                .onAppear {
                    prefetchArtwork(for: snapshot)
                }
        } else {
            Color.clear
                .allowsHitTesting(false)
        }
    }

    private func prefetchArtwork(for snapshot: Snapshot) {
        var urls: [URL] = []

        if let bg = plexService.backgroundArtworkURL(for: snapshot.now.media, width: 1280, height: 720, blur: 0) {
            urls.append(bg)
        }
        if let logo = plexService.logoArtworkURL(for: snapshot.now.media, width: 800, height: 300) {
            urls.append(logo)
        }

        for entry in snapshot.upcoming.prefix(6) {
            if let poster = plexService.posterArtworkURL(for: entry.media, width: 600, height: 900) {
                urls.append(poster)
            }
        }

        for url in urls {
            if prefetchedURLs.contains(url) { continue }

            Task {
                _ = await MainActor.run {
                    prefetchedURLs.insert(url)
                }

                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled else { return }
                    if let image = UIImage(data: data) {
                        PlexImageCache.shared.insert(image, for: url)
                    }
                } catch {
                    _ = await MainActor.run {
                        prefetchedURLs.remove(url)
                    }
                }
            }
        }
    }
}

// MARK: - Menu Handling

private extension ChannelRowView {
    private func handleMenuSelection(_ action: MenuAction) {
        guard let target = menuTarget else { return }
        defer { menuTarget = nil }

        if action == .delete {
            onMenuAction(channel, action)
            return
        }
        
        switch target {
        case .now:
            onMenuAction(channel, action)
        case .upNext(let media):
            onItemMenuAction(channel, media, action)
        }
    }
}

// MARK: - Snapshot & Formatting

private extension ChannelRowView {
    private func makeSnapshot(at date: Date) -> Snapshot? {
        guard let position = channel.playbackPosition(at: date) else { return nil }

        var entries: [Snapshot.Entry] = []
        if !channel.items.isEmpty {
            let total = channel.items.count
            var nextIndex = (position.index + 1) % total
            while entries.count < min(6, total - 1) {
                if nextIndex == position.index { break }
                entries.append(Snapshot.Entry(index: nextIndex, media: channel.items[nextIndex]))
                nextIndex = (nextIndex + 1) % total
            }
        }

        let nowEntry = Snapshot.Entry(index: position.index, media: position.media)
        let remaining = max(0, position.media.duration - position.offset)
        return Snapshot(
            now: nowEntry,
            offset: position.offset,
            remaining: remaining,
            upcoming: entries,
            timestamp: date
        )
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
