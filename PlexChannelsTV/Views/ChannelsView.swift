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

    private struct LibrarySelection: Identifiable {
        let library: PlexLibrary
        var id: String { library.uuid }
    }

    private enum Destination: Hashable {
        case channel(Channel)
        case quickPlay(LibraryPreviewItem)
    }

    @State private var path: [Destination] = []
    @State private var showLibraryPicker = false
    @State private var pickedLibrary: LibrarySelection?
    @State private var previewItems: [LibraryPreviewItem] = []
    @State private var isLoadingPreviews = false
    @State private var hasAutoPresentedPicker = false
    @State private var quickPlayError: String?

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
                onLibraryChosen: { library in
                    if let existing = channelStore.channel(for: library) {
                        showLibraryPicker = false
                        focusChannel(existing)
                    } else {
                        pickedLibrary = LibrarySelection(library: library)
                        showLibraryPicker = false
                    }
                },
                onCancel: {
                    showLibraryPicker = false
                }
            )
        }
        .sheet(item: $pickedLibrary) { selection in
            ChannelWizardView(
                library: selection.library,
                onComplete: { channel in
                    pickedLibrary = nil
                    hasAutoPresentedPicker = true
                    focusChannel(channel)
                },
                onCancel: {
                    pickedLibrary = nil
                    if channelStore.channels.isEmpty {
                        headerAddFocused = true
                    }
                }
            )
            .environmentObject(plexService)
            .environmentObject(channelStore)
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
                                PosterButton(item: item) {
                                    playPreviewItem(item)
                                }
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
                NavigationLink(value: Destination.channel(channel)) {
                    ChannelRowView(
                        channel: channel,
                        isFocused: focusedChannelID == channel.id
                    )
                }
                .buttonStyle(.plain)
                .focusable(true)
                .focused($focusedChannelID, equals: channel.id)
            }
        }
    }

    private func evaluateInitialState() {
        if channelStore.channels.isEmpty {
            if !hasAutoPresentedPicker && !showLibraryPicker && pickedLibrary == nil {
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
                        media: media,
                        streamURL: nil
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
        let preferredTypes: Set<PlexMediaType> = [.movie, .show, .episode]
        if let match = libraries.first(where: { preferredTypes.contains($0.type) }) {
            return match
        }
        return libraries.first
    }

    private func playPreviewItem(_ item: LibraryPreviewItem) {
        Task {
            do {
                let url = try await plexService.quickPlayURL(for: item.media)
                let enriched = item.withStreamURL(url)
                await MainActor.run {
                    print("[ChannelsView] Quick play prepared for \(item.title)")
                    path.append(.quickPlay(enriched))
                }
            } catch {
                await MainActor.run {
                    print("[ChannelsView] Quick play failed for \(item.title): \(error)")
                    quickPlayError = error.localizedDescription
                }
            }
        }
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

}

private struct PosterButton: View {
    let item: LibraryPreviewItem
    var action: () -> Void

    @State private var isFocused = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: item.thumbURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    case .failure:
                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 200, height: 300)
                            .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.7)))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    case .empty:
                        ProgressView()
                            .frame(width: 200, height: 300)
                    @unknown default:
                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 200, height: 300)
                            .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.7)))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(width: 200)
        }
        .buttonStyle(.plain)
        .focusableCompat { focused in
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocused = focused
            }
        }
        .scaleEffect(isFocused ? 1.08 : 1.0)
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(isFocused ? 1 : 0), lineWidth: 4)
                .shadow(color: isFocused ? Color.accentColor.opacity(0.45) : .clear, radius: 12, y: 6)
        )
    }
}

private struct ChannelRowView: View {
    let channel: Channel
    let isFocused: Bool

    @State private var hasLoggedNowNext = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.accentColor.opacity(isFocused ? 1 : 0), lineWidth: 4)
                )
                .shadow(color: isFocused ? Color.accentColor.opacity(0.4) : .clear, radius: 16, y: 8)

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
                            let nowTitle = playback.media.metadata?.title ?? playback.media.title
                            Text("Now: \(nowTitle) · \(formattedTime(remaining)) left")
                                .font(.callout)
                                .foregroundStyle(.primary)
                        } else {
                            Text("Now: Schedule pending…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if let next = channel.nextUp(after: now) {
                            let nextTitle = next.metadata?.title ?? next.title
                            Text("Next: \(nextTitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .frame(height: 140)
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onAppear { logNowNextIfNeeded(at: Date()) }
        .onChange(of: channel.id) { _, _ in
            hasLoggedNowNext = false
            logNowNextIfNeeded(at: Date())
        }
    }

    private func logNowNextIfNeeded(at date: Date) {
        guard !hasLoggedNowNext else { return }
        guard let playback = channel.playbackState(at: date) else { return }
        let nowTitle = playback.media.metadata?.title ?? playback.media.title
        let remaining = channel.timeRemaining(at: date) ?? 0
        let next = channel.nextUp(after: date)
        let nextTitle = next?.metadata?.title ?? next?.title ?? "Unknown"
        DispatchQueue.main.async {
            hasLoggedNowNext = true
            print("[ChannelsView] Now/Next for \(channel.name): Now=\(nowTitle) (\(Int(remaining))s left) · Next=\(nextTitle)")
        }
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(max(0, interval))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct LibraryPreviewItem: Identifiable, Hashable {
    let id: String
    let title: String
    let thumbURL: URL?
    let media: Channel.Media
    let streamURL: URL?

    func withStreamURL(_ url: URL) -> LibraryPreviewItem {
        LibraryPreviewItem(id: id, title: title, thumbURL: thumbURL, media: media, streamURL: url)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LibraryPreviewItem, rhs: LibraryPreviewItem) -> Bool {
        lhs.id == rhs.id
    }
}
