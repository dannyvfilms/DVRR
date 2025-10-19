//
//  ChannelWizardView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import SwiftUI
import PlexKit

struct ChannelWizardView: View {
    let library: PlexLibrary
    var onComplete: (Channel) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore

    @State private var selectedLibraryIDs: Set<String>
    @State private var channelName: String
    @State private var shuffle = false
    @State private var step = 0

    @State private var genreFilterMode: GenreFilterMode = .contains
    @State private var genreInput: String = ""
    @State private var yearFilter: YearFilter = .none
    @State private var yearValue: String = ""
    @State private var durationFilter: DurationFilter = .none
    @State private var durationValue: String = ""
    @State private var sortOrder: SortOrder = .random

    @State private var filteredMedia: [Channel.Media] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSuccessToast = false
    @State private var hasEditedName = false
    @State private var isUpdatingName = false


    init(library: PlexLibrary, onComplete: @escaping (Channel) -> Void, onCancel: @escaping () -> Void) {
        self.library = library
        self.onComplete = onComplete
        self.onCancel = onCancel
        _selectedLibraryIDs = State(initialValue: [library.uuid])
        _channelName = State(initialValue: library.title ?? "Channel")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                switch step {
                case 0:
                    librarySelectionStep
                case 1:
                    filtersStep
                case 2:
                    sortStep
                default:
                    previewStep
                }

                Spacer()

                HStack {
                    Button(step == 0 ? "Cancel" : "Back") {
                        if step == 0 {
                            onCancel()
                        } else {
                            step = max(0, step - 1)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(step < 3 ? "Next" : "Create Channel") {
                        if step < 3 {
                            step += 1
                            if step == 3 {
                                Task { await buildPreview() }
                            }
                        } else {
                            Task { await createChannel() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(nextButtonDisabled)
                }
            }
            .padding()
            .navigationTitle("Create Channel")
            .task { updateSuggestedNameIfNeeded() }
        }
        .overlay(alignment: .top) {
            if showSuccessToast {
                Text("Channel created")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: showSuccessToast)
        .onChange(of: selectedLibraryIDs) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: genreInput) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: yearFilter) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: yearValue) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: durationFilter) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: durationValue) { _, _ in updateSuggestedNameIfNeeded() }
        .onChange(of: channelName) { _, _ in
            if isUpdatingName {
                isUpdatingName = false
            } else {
                hasEditedName = true
            }
        }
    }

    private var availableLibraries: [PlexLibrary] {
        var libs = (plexService.session?.libraries ?? []).filter { lib in
            lib.type == .movie || lib.type == .show || lib.type == .episode
        }
        if !libs.contains(where: { $0.uuid == library.uuid }) {
            libs.insert(library, at: 0)
        }
        return libs
    }

    private var selectedLibraries: [PlexLibrary] {
        availableLibraries.filter { selectedLibraryIDs.contains($0.uuid) }
    }

    private var primaryType: PlexMediaType {
        selectedLibraries.first?.type ?? library.type
    }

    private func toggleLibrary(_ library: PlexLibrary) {
        if selectedLibraryIDs.contains(library.uuid) {
            selectedLibraryIDs.remove(library.uuid)
        } else {
            selectedLibraryIDs.insert(library.uuid)
        }
        updateSuggestedNameIfNeeded()
    }

    private var librarySelectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 · Libraries")
                .font(.title3)

            Text("Select one or more libraries to include in this channel.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(availableLibraries, id: \.uuid) { lib in
                        SelectableLibraryRow(
                            library: lib,
                            isSelected: selectedLibraryIDs.contains(lib.uuid)
                        ) {
                            toggleLibrary(lib)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 260)

            TextField("Channel Name", text: $channelName)
                .padding(.horizontal)
                .frame(maxWidth: 480, minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                )

            Toggle("Shuffle order", isOn: $shuffle)

            Text("Start time: Now")
                .font(.callout)
                .foregroundStyle(.secondary)

            if selectedLibraries.isEmpty {
                Text("Select at least one library to continue.")
                    .foregroundStyle(.red)
            }
        }
    }

    private var filtersStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Step 2 · Filters")
                .font(.title3)

            VStack(alignment: .leading, spacing: 12) {
                Text("Genre")
                    .font(.headline)
                Picker("Mode", selection: $genreFilterMode) {
                    ForEach(GenreFilterMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Genre", text: $genreInput)
                    .padding(.horizontal)
                    .frame(maxWidth: 320, minHeight: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Year")
                    .font(.headline)
                Picker("Year Filter", selection: $yearFilter) {
                    ForEach(YearFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if yearFilter != .none {
                    TextField("Year", text: $yearValue)
                        .keyboardType(.numberPad)
                        .padding(.horizontal)
                        .frame(maxWidth: 200, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Duration (minutes)")
                    .font(.headline)
                Picker("Duration Filter", selection: $durationFilter) {
                    ForEach(DurationFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                if durationFilter != .none {
                    TextField("Minutes", text: $durationValue)
                        .keyboardType(.numberPad)
                        .padding(.horizontal)
                        .frame(maxWidth: 200, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.1)))
                }
            }
        }
    }

    private var sortStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Step 3 · Sorting")
                .font(.title3)

            Picker("Sort Order", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.segmented)

            Text("Shuffle option from step 1 still applies. Sorting is performed after filtering.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 4 · Preview")
                .font(.title3)

            if isLoading {
                ProgressView("Preparing preview…")
            } else if filteredMedia.isEmpty {
                Text("No items matched your filters.")
                    .foregroundStyle(.secondary)
            } else {
                let previewChannel = makePreviewChannel()
                if let playback = previewChannel.playbackState() {
                    let remaining = previewChannel.timeRemaining() ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If you tuned in now:")
                            .font(.headline)
                        Text(playback.media.title)
                            .font(.title2)
                        Text("Elapsed \(formatted(time: playback.offset)) · \(formatted(time: remaining)) left")
                            .foregroundStyle(.secondary)
                    }
                }

                if let next = previewChannel.nextUp() {
                    Text("Up Next: \(next.title)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nextButtonDisabled: Bool {
        switch step {
        case 0:
            return selectedLibraries.isEmpty
        case 1:
            return false
        case 2:
            return false
        case 3:
            return filteredMedia.isEmpty || isLoading
        default:
            return true
        }
    }

    private func buildPreview() async {
        isLoading = true
        defer { isLoading = false }

        await MainActor.run {
            filteredMedia = []
            errorMessage = nil
        }
        let items = await fetchAllItems()
        let medias = items.compactMap(Channel.Media.from)
        let filtered = applyFilters(to: medias)
        let sorted = applySort(to: filtered)
        let rawCount = items.count
        let playableCount = medias.count
        let filteredCount = filtered.count
        let finalCount = sorted.count
        let logMessage = "[ChannelWizard] Filter pipeline: raw=" + String(rawCount)
            + " | playable=" + String(playableCount)
            + " | filtered=" + String(filteredCount)
            + " | final=" + String(finalCount)
        print(logMessage)

        await MainActor.run {
            self.filteredMedia = sorted
            updateSuggestedNameIfNeeded()
        }
    }

    private func fetchAllItems() async -> [PlexMediaItem] {
        var collected: [PlexMediaItem] = []
        for library in selectedLibraries {
            do {
                let items = try await plexService.fetchLibraryItems(for: library, limit: 800)
                collected.append(contentsOf: items)
                print("[ChannelWizard] Loaded \(items.count) items from \(library.title ?? "library")")
            } catch {
                print("[ChannelWizard] Failed to load library \(library.title ?? "library"): \(error)")
            }
        }
        return collected
    }

    private func applyFilters(to items: [Channel.Media]) -> [Channel.Media] {
        items.filter { media in
            guard matchesPrimaryType(media), filterByGenre(media), filterByYear(media), filterByDuration(media) else { return false }
            return true
        }
    }

    private func matchesPrimaryType(_ media: Channel.Media) -> Bool {
        guard let type = media.metadata?.type else { return true }
        switch primaryType {
        case .movie:
            return type == .movie
        case .show, .episode:
            return type == .episode || type == .show
        default:
            return true
        }
    }

    private func filterByGenre(_ media: Channel.Media) -> Bool {
        let query = genreInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let tags = media.metadata?.genres ?? []
        switch genreFilterMode {
        case .contains:
            return tags.contains { $0.localizedCaseInsensitiveContains(query) }
        case .equals:
            return tags.contains { $0.compare(query, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
    }

    private func filterByYear(_ media: Channel.Media) -> Bool {
        guard yearFilter != .none else { return true }
        let trimmed = yearValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numeric = Int(trimmed) else { return false }
        guard let metadataYear = media.metadata?.year else { return false }

        switch yearFilter {
        case .none:
            return true
        case .equal:
            return metadataYear == numeric
        case .greaterOrEqual:
            return metadataYear >= numeric
        case .lessOrEqual:
            return metadataYear <= numeric
        }
    }

    private func filterByDuration(_ media: Channel.Media) -> Bool {
        guard durationFilter != .none else { return true }
        let trimmed = durationValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numeric = Int(trimmed) else { return false }
        let durationMinutes = Int(media.duration / 60)

        switch durationFilter {
        case .none:
            return true
        case .greaterOrEqual:
            return durationMinutes >= numeric
        case .lessOrEqual:
            return durationMinutes <= numeric
        }
    }

    private func applySort(to items: [Channel.Media]) -> [Channel.Media] {
        var result: [Channel.Media]
        switch sortOrder {
        case .random:
            result = items.shuffled()
        case .titleAZ:
            result = items.sorted { ($0.metadata?.title ?? "") < ($1.metadata?.title ?? "") }
        case .dateAddedNewest:
            result = items.sorted { ($0.metadata?.addedAt ?? .distantPast) > ($1.metadata?.addedAt ?? .distantPast) }
        }
        if shuffle {
            result.shuffle()
        }
        return result
    }

    private func defaultChannelName() -> String {
        let base: String
        if selectedLibraries.count > 1 {
            base = "\(typeLabel(for: primaryType)) — Mix"
        } else {
            base = selectedLibraries.first?.title ?? library.title ?? "Channel"
        }

        var components: [String] = [base]

        if !genreInput.isEmpty {
            components.append("Genre: \(genreInput)")
        }
        if yearFilter != .none, let year = Int(yearValue) {
            components.append("Year \(yearFilter.summary) \(year)")
        }
        if durationFilter != .none, let duration = Int(durationValue) {
            components.append("Duration \(durationFilter.summary) \(duration)m")
        }

        return components.joined(separator: " — ")
    }

    private func updateSuggestedNameIfNeeded() {
        guard !hasEditedName else { return }
        isUpdatingName = true
        channelName = defaultChannelName()
        isUpdatingName = false
    }

    private func typeLabel(for type: PlexMediaType) -> String {
        switch type {
        case .movie: return "Movies"
        case .show, .season, .episode: return "TV"
        default: return "Channel"
        }
    }

    private func createChannel() async {
        guard !filteredMedia.isEmpty else {
            errorMessage = "No items matched your filters."
            return
        }

        updateSuggestedNameIfNeeded()
        let items = applySort(to: filteredMedia)
        let channel = Channel(
            name: channelName.isEmpty ? defaultChannelName() : channelName,
            libraryKey: UUID().uuidString,
            libraryType: primaryType,
            scheduleAnchor: Date(),
            items: items
        )

        let appended = channelStore.addChannel(channel)
        if appended {
            print("[ChannelWizard] Created channel \(channel.name) with \(items.count) items")
            await MainActor.run {
                showSuccessToast = true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                showSuccessToast = false
                onComplete(channel)
            }
        } else {
            await MainActor.run {
                errorMessage = "A similar channel already exists."
            }
        }
    }

    private func makePreviewChannel() -> Channel {
        Channel(
            name: channelName.isEmpty ? defaultChannelName() : channelName,
            libraryKey: "preview",
            libraryType: library.type,
            scheduleAnchor: Date(),
            items: filteredMedia
        )
    }

    private func formatted(time interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

private struct SelectableLibraryRow: View {
    let library: PlexLibrary
    let isSelected: Bool
    var action: () -> Void

    @State private var isFocused = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: iconName(for: library.type))
                    .foregroundColor(.accentColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.title ?? "Library")
                        .font(.headline)
                    Text(library.type.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 3)
                    .shadow(color: isFocused ? Color.accentColor.opacity(0.35) : .clear, radius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusableCompat { focus in
            withAnimation(.easeInOut(duration: 0.2)) { isFocused = focus }
        }
        .scaleEffect(isFocused ? 1.04 : 1.0)
    }

    private func iconName(for type: PlexMediaType) -> String {
        switch type {
        case .movie: return "film.fill"
        case .show, .season, .episode: return "tv.fill"
        case .artist, .album, .track: return "music.note.list"
        case .photo, .picture, .photoAlbum: return "photo.fill.on.rectangle.fill"
        default: return "play.rectangle.fill"
        }
    }
}

    enum GenreFilterMode: CaseIterable {
        case contains
        case equals

        var label: String {
            switch self {
            case .contains:
                return "Contains"
            case .equals:
                return "Equals"
            }
        }
    }

    enum YearFilter: CaseIterable {
        case none
        case equal
        case greaterOrEqual
        case lessOrEqual

        var label: String {
            switch self {
            case .none:
                return "All"
            case .equal:
                return "="
            case .greaterOrEqual:
                return "≥"
            case .lessOrEqual:
                return "≤"
            }
        }

        var summary: String {
            switch self {
            case .none:
                return ""
            case .equal:
                return "="
            case .greaterOrEqual:
                return "≥"
            case .lessOrEqual:
                return "≤"
            }
        }
    }

    enum DurationFilter: CaseIterable {
        case none
        case greaterOrEqual
        case lessOrEqual

        var label: String {
            switch self {
            case .none:
                return "All"
            case .greaterOrEqual:
                return "≥"
            case .lessOrEqual:
                return "≤"
            }
        }

        var summary: String {
            switch self {
            case .none:
                return ""
            case .greaterOrEqual:
                return "≥"
            case .lessOrEqual:
                return "≤"
            }
        }
    }

    enum SortOrder: CaseIterable {
        case random
        case titleAZ
        case dateAddedNewest

        var label: String {
            switch self {
            case .random:
                return "Random"
            case .titleAZ:
                return "Title A–Z"
            case .dateAddedNewest:
                return "Newest"
            }
        }
    }
}
