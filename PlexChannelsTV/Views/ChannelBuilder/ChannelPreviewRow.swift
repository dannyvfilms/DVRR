//
//  ChannelPreviewRow.swift
//  PlexChannelsTV
//
//  Created by Codex on 01/19/26.
//

import SwiftUI
import PlexKit

struct ChannelPreviewRow: View {
    let previewMedia: [Channel.Media]
    let plexService: PlexService
    let countState: ChannelBuilderViewModel.CountState?
    let availableSortKeys: [SortDescriptor.SortKey]
    let mediaType: PlexMediaType
    @Binding var sortDescriptor: SortDescriptor
    @Binding var shuffleEnabled: Bool
    @Binding var channelName: String
    let onRefreshLibrary: (() -> Void)?

    private let cardWidth: CGFloat = 180
    private let cardHeight: CGFloat = 270

    @State private var showSortKeyDialog = false
    @State private var showSortOrderDialog = false
    @State private var showNameEditor = false

    @FocusState private var focusedCard: FocusTarget?

    enum FocusTarget: Hashable {
        case name
        case sortKey
        case sortOrder
        case count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            posters
        }
        .sheet(isPresented: $showNameEditor) {
            ChannelNameEditorSheet(initialName: channelName) { newName in
                channelName = newName
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            channelNameButton

            Spacer()

            sortKeyButton
            sortOrderControl

            if let countState {
                CountBadge(state: countState, mediaType: mediaType, onRefreshLibrary: onRefreshLibrary)
            }
        }
    }

    private var channelNameButton: some View {
        badgeButton(text: channelNameDisplay, icon: "square.and.pencil", focus: .name) {
            showNameEditor = true
        }
    }

    private var sortKeyButton: some View {
        badgeButton(text: sortDescriptor.key.displayName, icon: "chevron.down", focus: .sortKey) {
            showSortKeyDialog = true
        }
        .confirmationDialog("Sort By", isPresented: $showSortKeyDialog, titleVisibility: .visible) {
            ForEach(sortKeysForDialog, id: \.self) { key in
                Button {
                    sortDescriptor.key = key
                    if key.supportsAscending {
                        sortDescriptor.order = key.defaultOrder
                    } else {
                        sortDescriptor.order = .ascending
                    }
                    if key == .random {
                        shuffleEnabled = false
                    }
                } label: {
                    HStack {
                        Text(key.displayName)
                        Spacer()
                        if sortDescriptor.key == key {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var sortOrderControl: some View {
        if sortDescriptor.key.supportsAscending {
            badgeButton(text: sortOrderLabel, icon: "chevron.down", focus: .sortOrder) {
                showSortOrderDialog = true
            }
            .confirmationDialog("Sort Order", isPresented: $showSortOrderDialog, titleVisibility: .visible) {
                Button {
                    sortDescriptor.order = .ascending
                    shuffleEnabled = false
                } label: {
                    orderOptionLabel(.ascending)
                }

                Button {
                    sortDescriptor.order = .descending
                    shuffleEnabled = false
                } label: {
                    orderOptionLabel(.descending)
                }

                Button(shuffleEnabled ? "Disable Shuffle" : "Enable Shuffle") {
                    shuffleEnabled.toggle()
                }

                Button("Cancel", role: .cancel) {}
            }
        } else {
            badgeStatus(text: "Random")
        }
    }

    private var posters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 24) {
                if previewMedia.isEmpty {
                    ForEach(0..<8, id: \.self) { _ in
                        PlaceholderPosterCard(width: cardWidth, height: cardHeight)
                    }
                } else {
                    ForEach(previewMedia.prefix(20)) { media in
                        PreviewPosterCard(
                            media: media,
                            plexService: plexService,
                            width: cardWidth,
                            height: cardHeight
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: cardHeight + 80)  // Increased to 80 to prevent text cutoff
        .focusable(false)
    }

    private func badgeButton(
        text: String,
        icon: String?,
        focus: FocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            badgeLabel(text: text, icon: icon, isFocused: focusedCard == focus)
        }
        .clipShape(Capsule())
        .buttonStyle(.plain)
        .focused($focusedCard, equals: focus)
        .scaleEffect(focusedCard == focus ? 1.015 : 1.0)
        .shadow(
            color: focusedCard == focus ? .accentColor.opacity(0.35) : .clear,
            radius: 8,
            x: 0,
            y: 2
        )
        .animation(.easeInOut(duration: 0.15), value: focusedCard == focus)
    }

    private func badgeStatus(text: String) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.vertical, PreviewBadgeStyle.verticalPadding)
        .padding(.horizontal, PreviewBadgeStyle.horizontalPadding)
        .background(
            Capsule()
                .fill(PreviewBadgeStyle.background)
        )
    }

    private func badgeLabel(text: String, icon: String?, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if let icon {
                Image(systemName: icon)
                    .imageScale(.small)
            }
        }
        .padding(.vertical, PreviewBadgeStyle.verticalPadding)
        .padding(.horizontal, PreviewBadgeStyle.horizontalPadding)
        .background(
            Capsule()
                .fill(isFocused ? PreviewBadgeStyle.focusedBackground : PreviewBadgeStyle.background)
        )
    }

    private func orderOptionLabel(_ order: SortDescriptor.Order) -> some View {
        HStack {
            Text(order.displayName)
            Spacer()
            if !shuffleEnabled, sortDescriptor.order == order {
                Image(systemName: "checkmark")
            }
        }
    }

    private var channelNameDisplay: String {
        let trimmed = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Channel Name" : trimmed
    }

    private var sortOrderLabel: String {
        if shuffleEnabled {
            return "Shuffle"
        }
        return sortDescriptor.order.displayName
    }

    private var sortKeysForDialog: [SortDescriptor.SortKey] {
        var keys = availableSortKeys
        if !keys.contains(sortDescriptor.key) {
            keys.append(sortDescriptor.key)
        }
        return keys
    }
}

private struct CountBadge: View {
    let state: ChannelBuilderViewModel.CountState
    let mediaType: PlexMediaType
    let onRefreshLibrary: (() -> Void)?
    
    @State private var showMenu = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            // Primary action - no-op for count badge
        } label: {
            HStack(spacing: 8) {
                if state.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.8)
                }
                Text(countLabel)
                    .font(.footnote.bold())
            }
            .padding(.vertical, PreviewBadgeStyle.verticalPadding)
            .padding(.horizontal, PreviewBadgeStyle.horizontalPadding)
            .background(
                Capsule()
                    .fill(PreviewBadgeStyle.background)
            )
        }
        .clipShape(Capsule())
        .buttonStyle(.plain)
        .scaleEffect(isFocused ? 1.015 : 1.0)
        .shadow(
            color: isFocused ? .accentColor.opacity(0.35) : .clear,
            radius: 8,
            x: 0,
            y: 2
        )
        .onPlayPauseCommand {
            showMenu = true
        }
        .focused($isFocused)
        .confirmationDialog(menuTitle, isPresented: $showMenu, titleVisibility: .visible) {
            if let onRefreshLibrary {
                Button("Refresh Library") {
                    onRefreshLibrary()
                }
            }
            
            Button("Cancel", role: .cancel) {}
        }
    }

    private var countLabel: String {
        if let total = state.total {
            let unit = mediaType == .episode ? "episodes" : "items"
            return state.approximate ? "~\(total) \(unit)" : "\(total) \(unit)"
        }
        if state.isLoading {
            if let progress = state.progressCount {
                return "\(progress) so far…"
            }
            return "Counting…"
        }
        return "—"
    }
    
    private var menuTitle: String {
        if let lastUpdated = state.lastUpdated {
            return "Last Updated: \(formatDate(lastUpdated))"
        }
        return "Library Cache"
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct PreviewPosterCard: View {
    let media: Channel.Media
    let plexService: PlexService
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            .scaleEffect(0.6)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Color.gray.opacity(0.3)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

private struct PlaceholderPosterCard: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: width, height: height)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary.opacity(0.5))
                )

            Text(" ")
                .font(.caption)
                .frame(width: width, alignment: .leading)
        }
    }
}

private struct ChannelNameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var workingName: String
    private let onSave: (String) -> Void

    @FocusState private var isFieldFocused: Bool

    init(initialName: String, onSave: @escaping (String) -> Void) {
        _workingName = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 32) {
            Text("Channel Name")
                .font(.title2.bold())

            TextField("Name", text: $workingName)
                .textFieldStyle(.plain)
                .padding(.horizontal, 24)
                .frame(width: 520, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .focused($isFieldFocused)

            HStack(spacing: 24) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save") {
                    let trimmed = workingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isFieldFocused = true
            }
        }
    }
}

private enum PreviewBadgeStyle {
    static let background = Color.white.opacity(0.12)
    static let focusedBackground = Color.white.opacity(0.18)
    static let horizontalPadding: CGFloat = 18
    static let verticalPadding: CGFloat = 10
}
