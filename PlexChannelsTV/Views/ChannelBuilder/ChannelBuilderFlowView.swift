//
//  ChannelBuilderFlowView.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI
import PlexKit

struct ChannelBuilderFlowView: View {
    @StateObject private var viewModel: ChannelBuilderViewModel
    @State private var isCreating = false
    @State private var previewMedia: [Channel.Media] = []
    @State private var isLoadingPreview = false
    @FocusState private var focusedButton: FocusableButton?
    private let onComplete: (Channel) -> Void
    private let onCancel: () -> Void
    private let plexService: PlexService
    
    private enum FocusableButton: Hashable {
        case cancel
        case next
        case back
        case create
    }

    init(
        plexService: PlexService,
        channelStore: ChannelStore,
        libraries: [PlexLibrary],
        existingChannel: Channel? = nil,
        onComplete: @escaping (Channel) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.plexService = plexService
        _viewModel = StateObject(wrappedValue: ChannelBuilderViewModel(
            plexService: plexService,
            channelStore: channelStore,
            libraries: libraries,
            existingChannel: existingChannel
        ))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        mainContent
            .alert(item: errorBinding) { alert in
                Alert(title: Text("Channel Builder"), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            .onChange(of: viewModel.step) { _, newStep in
                handleStepChange(newStep)
            }
            .onChange(of: viewModel.previewUpdateTrigger) { _, _ in
                handlePreviewUpdate()
            }
            .onChange(of: viewModel.draft.sort) { _, _ in
                handleSortOrOptionChange()
            }
            .onChange(of: viewModel.draft.options.shuffle) { _, _ in
                handleSortOrOptionChange()
            }
    }
    
    private var mainContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    content
                        .focusSectionIfAvailable()
                    Spacer(minLength: previewSpacerLength)

                    previewRow
                    
                    Spacer(minLength: 20)
                    
                    footer
                        .focusSectionIfAvailable()
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
        }
    }
    
    @ViewBuilder
    private var previewRow: some View {
        if case .rules(let index) = viewModel.step,
           viewModel.selectedLibraryRefs.indices.contains(index) {
            let ref = viewModel.selectedLibraryRefs[index]
            if let library = viewModel.library(for: ref.id) {
                let sortBinding = Binding(
                    get: { viewModel.draft.sort },
                    set: { viewModel.draft.sort = $0 }
                )
                let shuffleBinding = Binding(
                    get: { viewModel.draft.options.shuffle },
                    set: { viewModel.draft.options.shuffle = $0 }
                )
                ChannelPreviewRow(
                    previewMedia: previewMedia,
                    plexService: plexService,
                    countState: viewModel.counts[ref.id],
                    availableSortKeys: viewModel.sortCatalog.availableSorts(for: library),
                    mediaType: library.type,
                    sortDescriptor: sortBinding,
                    shuffleEnabled: shuffleBinding,
                    channelName: $viewModel.draft.name,
                    onRefreshLibrary: {
                        viewModel.refreshLibraryCache(for: ref.id)
                    }
                )
            }
        }
    }
    
    private var errorBinding: Binding<BuilderAlert?> {
        Binding(
            get: {
                viewModel.errorMessage.map { BuilderAlert(id: UUID(), message: $0) }
            },
            set: { newValue in
                if newValue == nil {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
    
    private func handleStepChange(_ newStep: ChannelBuilderViewModel.Step) {
        if case .rules = newStep {
            fetchPreviewMedia()
        } else {
            previewMedia = []
        }
    }
    
    private func handlePreviewUpdate() {
        if case .rules = viewModel.step {
            fetchPreviewMedia()
        }
    }

    private func handleSortOrOptionChange() {
        if case .rules = viewModel.step {
            fetchPreviewMedia()
        }
    }

    private var previewSpacerLength: CGFloat {
        if case .rules = viewModel.step {
            return 12
        }
        return 20
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .libraries:
            librariesStep
        case .rules(let index):
            rulesStep(index: index)
        }
    }

    private var librariesStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Step 1 · Libraries")
                .font(.title2.bold())
            Text("Select one or more libraries to build your channel. Only libraries with the same media type can be combined.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if viewModel.allLibraries.isEmpty {
                Text("No libraries available. Connect to Plex and refresh.")
                    .foregroundStyle(.secondary)
            } else {
                let selectedIDs = Set(viewModel.selectedLibraryRefs.map(\.id))
                LibraryMultiPickerView(
                    libraries: viewModel.allLibraries,
                    selectedIDs: selectedIDs,
                    cacheStore: viewModel.cacheStore,
                    onToggle: viewModel.toggleLibrary
                )
                .onChange(of: viewModel.selectedLibraryRefs.count) { oldCount, newCount in
                    AppLoggers.channel.info("event=builder.selection.changed oldCount=\(oldCount) newCount=\(newCount) isEmpty=\(viewModel.selectedLibraryRefs.isEmpty)")
                }
            }
        }
    }

    @ViewBuilder
    private func rulesStep(index: Int) -> some View {
        if viewModel.selectedLibraryRefs.indices.contains(index) {
            let ref = viewModel.selectedLibraryRefs[index]
            if let library = viewModel.library(for: ref.id) {
                let binding = viewModel.binding(for: ref)
                VStack(alignment: .leading, spacing: 24) {
                    Text("Step 2 · Rules (\(index + 1) of \(viewModel.selectedLibraryRefs.count)) · \(library.title ?? "Library")")
                        .font(.title2.bold())
                    RuleGroupBuilderView(
                        spec: binding,
                        library: library,
                        availableFields: viewModel.availableFields(for: library),
                        filterCatalog: viewModel.filterCatalog,
                        countState: viewModel.counts[ref.id],
                        onSpecChange: viewModel.updateSpec,
                        onMenuStateChange: viewModel.setMenuOpen
                    )
                }
            } else {
                Text("Library unavailable")
            }
        } else {
            Text("Select at least one library to continue.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 24) {
            // Cancel button - left aligned with visible border
            Button("Cancel") {
                onCancel()
            }
            .buttonStyle(.bordered)
            .disabled(isCreating)
            .focused($focusedButton, equals: .cancel)

            Spacer(minLength: 40)

            // Navigation buttons - right aligned with spacing to prevent overlap
            HStack(spacing: 24) {
                switch viewModel.step {
                case .libraries:
                    let isDisabled = viewModel.selectedLibraryRefs.isEmpty
                    Button("Next") {
                        AppLoggers.channel.info("event=builder.next.tap step=libraries selected=\(viewModel.selectedLibraryRefs.count)")
                        viewModel.proceedFromLibraries()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
                    .focused($focusedButton, equals: .next)
                    .onAppear {
                        AppLoggers.channel.info("event=builder.next.appear isDisabled=\(isDisabled) selectedCount=\(viewModel.selectedLibraryRefs.count)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            focusedButton = .next
                        }
                    }
                    .onChange(of: viewModel.selectedLibraryRefs.count) { oldValue, newValue in
                        AppLoggers.channel.info("event=builder.next.update oldCount=\(oldValue) newCount=\(newValue) isDisabled=\(newValue == 0)")
                    }

                case .rules(let index):
                    Button("Back") {
                        viewModel.goBack(from: .rules(index: index))
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedButton, equals: .back)

                    if isCreating {
                        ProgressView("Creating…")
                            .progressViewStyle(.circular)
                            .frame(height: 44)
                    } else {
                        let isLast = index >= viewModel.selectedLibraryRefs.count - 1
                        let buttonText: String = {
                            if isLast {
                                return viewModel.isEditing ? "Update Channel" : "Create Channel"
                            }
                            return "Next"
                        }()
                        Button(buttonText) {
                            if isLast {
                                Task {
                                    await createChannel()
                                }
                            } else {
                                AppLoggers.channel.info("event=builder.next.tap step=rules index=\(index)")
                                _ = viewModel.goToNextRulesStep(currentIndex: index)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLast && viewModel.draft.selectedLibraries.isEmpty)
                        .focused($focusedButton, equals: isLast ? .create : .next)
                        .onAppear {
                            focusedButton = isLast ? .create : .next
                        }
                    }
                }
            }
        }
    }

    private func fetchPreviewMedia() {
        guard !isLoadingPreview else { return }
        isLoadingPreview = true
        
        Task {
            let media = await viewModel.fetchPreviewMedia(limit: 20)
            await MainActor.run {
                self.previewMedia = media
                self.isLoadingPreview = false
            }
        }
    }

    @MainActor
    private func createChannel() async {
        if isCreating { return }
        guard !viewModel.draft.selectedLibraries.isEmpty else {
            viewModel.errorMessage = "Select at least one library before creating a channel."
            return
        }

        isCreating = true
        defer { isCreating = false }

        let startTime = Date()
        let draft = viewModel.draft
        AppLoggers.channel.info(
            "event=builder.compile.start libraryCount=\(draft.selectedLibraries.count) sort=\(draft.sort.key.rawValue, privacy: .public)"
        )

        var perLibraryCounts: [String: Int] = [:]
        var combinedMedia: [Channel.Media] = []
        var seenIDs = Set<String>()

        do {
            for ref in draft.selectedLibraries {
                guard let library = viewModel.library(for: ref.id) else { continue }
                let spec = viewModel.spec(for: ref)
                let mediaItems = try await viewModel.queryBuilder.buildChannelMedia(
                    library: library,
                    using: spec.rootGroup,
                    sort: nil,
                    limit: nil
                )
                perLibraryCounts[ref.id] = mediaItems.count
                for media in mediaItems where seenIDs.insert(media.id).inserted {
                    combinedMedia.append(media)
                }
            }

            guard !combinedMedia.isEmpty else {
                viewModel.errorMessage = "No media matched these filters."
                AppLoggers.channel.error("event=builder.compile.fail reason=\"empty_results\"")
                return
            }

            let channelID = UUID()
            var finalMedia = combinedMedia

            if draft.sort.key != .random && !draft.options.shuffle {
                finalMedia = finalMedia.sorted(using: draft.sort)
            }

            if draft.sort.key == .random || draft.options.shuffle {
                var generator = SeededRandomNumberGenerator(seed: deterministicSeed(for: channelID))
                finalMedia.shuffle(using: &generator)
            }

            let sources = draft.selectedLibraries.map {
                Channel.SourceLibrary(
                    id: $0.id,
                    key: $0.key,
                    title: $0.title,
                    type: $0.type
                )
            }

            let primaryType = draft.primaryMediaType() ?? .movie
            let primaryKey = draft.selectedLibraries.first?.key ?? channelID.uuidString
            let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmedName.isEmpty ? defaultName(for: primaryType) : trimmedName

            let isEditing = viewModel.isEditing
            let finalChannelID = isEditing ? viewModel.existingChannelID! : channelID
            
            // Preserve scheduleAnchor when editing
            let preservedScheduleAnchor: Date = {
                if isEditing, let existingChannel = viewModel.channelStore.channels.first(where: { $0.id == finalChannelID }) {
                    return existingChannel.scheduleAnchor
                }
                return Date()
            }()
            
            let channel = Channel(
                id: finalChannelID,
                name: finalName,
                libraryKey: primaryKey,
                libraryType: primaryType,
                scheduleAnchor: preservedScheduleAnchor,
                items: finalMedia,
                sourceLibraries: sources,
                options: Channel.Options(shuffle: draft.options.shuffle),
                provenance: .filters(draft)
            )

            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let countsSummary = perLibraryCounts.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            AppLoggers.channel.info(
                "event=builder.compile.ok perLibCounts=\(countsSummary, privacy: .public) total=\(channel.items.count) elapsedMs=\(elapsed) isEditing=\(isEditing)"
            )

            if isEditing {
                // Update existing channel - remove old one first
                if let existingChannel = viewModel.channelStore.channels.first(where: { $0.id == finalChannelID }) {
                    viewModel.channelStore.removeChannel(existingChannel)
                }
                // Add updated channel using addChannel method
                // Since we removed the old channel first, addChannel should succeed (no name conflict)
                let added = viewModel.channelStore.addChannel(channel)
                if !added {
                    // Name collision with different channel - this shouldn't happen but handle it
                    viewModel.errorMessage = "Failed to update channel: name conflict."
                    AppLoggers.channel.error(
                        "event=builder.update.fail channelID=\(finalChannelID.uuidString, privacy: .public) reason=\"name_conflict\""
                    )
                    return
                }
                AppLoggers.channel.info(
                    "event=builder.update.ok channelID=\(channel.id.uuidString, privacy: .public) itemCount=\(channel.items.count)"
                )
            } else {
                // Create new channel
                guard viewModel.channelStore.addChannel(channel) else {
                    viewModel.errorMessage = "A channel with this name already exists."
                    AppLoggers.channel.error(
                        "event=builder.persist.fail reason=\"duplicate_name\" channelName=\(channel.name, privacy: .public)"
                    )
                    return
                }
                AppLoggers.channel.info(
                    "event=builder.persist.ok channelID=\(channel.id.uuidString, privacy: .public) itemCount=\(channel.items.count)"
                )
            }

            onComplete(channel)
        } catch {
            viewModel.errorMessage = error.localizedDescription
            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            AppLoggers.channel.error(
                "event=builder.compile.fail error=\(String(describing: error), privacy: .public) elapsedMs=\(elapsed)"
            )
        }
    }
}

private struct BuilderAlert: Identifiable {
    let id: UUID
    let message: String
}

private extension ChannelBuilderFlowView {
    func deterministicSeed(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { buffer in
            let lower = buffer.load(as: UInt64.self)
            let upper = buffer.baseAddress!.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee
            return UInt64(littleEndian: lower) ^ UInt64(littleEndian: upper)
        }
    }

    func defaultName(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "Movies — Mix"
        case .episode:
            return "TV — Mix"
        default:
            return "Channel"
        }
    }
}
