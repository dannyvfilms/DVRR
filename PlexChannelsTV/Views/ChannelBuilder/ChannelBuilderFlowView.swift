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
    @FocusState private var focusedButton: FocusableButton?
    private let onComplete: (Channel) -> Void
    private let onCancel: () -> Void
    
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
        onComplete: @escaping (Channel) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: ChannelBuilderViewModel(
            plexService: plexService,
            channelStore: channelStore,
            libraries: libraries
        ))
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 32) {
                content
                    .focusSectionIfAvailable()
                Spacer(minLength: 20)
                footer
                    .focusSectionIfAvailable()
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.regularMaterial)
        }
        .alert(item: Binding(
            get: {
                viewModel.errorMessage.map { BuilderAlert(id: UUID(), message: $0) }
            },
            set: { newValue in
                if newValue == nil {
                    viewModel.errorMessage = nil
                }
            }
        )) { alert in
            Alert(title: Text("Channel Builder"), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.step {
        case .libraries:
            librariesStep
        case .rules(let index):
            rulesStep(index: index)
        case .sort:
            sortStep
        case .review:
            reviewStep
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("Step 2 · Rules (\(index + 1) of \(viewModel.selectedLibraryRefs.count))")
                        .font(.title2.bold())
                    RuleGroupBuilderView(
                        spec: binding,
                        library: library,
                        availableFields: viewModel.availableFields(for: library),
                        filterCatalog: viewModel.filterCatalog,
                        countState: viewModel.counts[ref.id],
                        onSpecChange: viewModel.updateSpec
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

    private var sortStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let first = viewModel.selectedLibraryRefs.first, let library = viewModel.library(for: first.id) {
                SortPickerView(
                    descriptor: $viewModel.draft.sort,
                    availableKeys: viewModel.sortCatalog.availableSorts(for: library)
                )
            } else {
                Text("Sort options will appear once a library is selected.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reviewStep: some View {
        ChannelBuilderReviewView(
            draft: $viewModel.draft,
            libraries: viewModel.selectedLibraryRefs,
            counts: viewModel.counts,
            totalItems: viewModel.totalItemCountEstimate()
        )
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

                case .rules, .sort:
                    Button("Back") {
                        switch viewModel.step {
                        case .rules(let index):
                            viewModel.goBack(from: .rules(index: index))
                        case .sort:
                            viewModel.goBack(from: .sort)
                        default:
                            break
                        }
                    }
                    .buttonStyle(.bordered)
                    .focused($focusedButton, equals: .back)

                    Button("Next") {
                        switch viewModel.step {
                        case .rules(let index):
                            viewModel.goToNextRulesStep(currentIndex: index)
                        case .sort:
                            viewModel.advanceFromSort()
                        default:
                            break
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focusedButton, equals: .next)

                case .review:
                    Button("Back") {
                        viewModel.goBack(from: .review)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                    .focused($focusedButton, equals: .back)

                    if isCreating {
                        ProgressView("Creating…")
                            .progressViewStyle(.circular)
                            .frame(height: 44)
                    } else {
                        Button("Create Channel") {
                            Task {
                                await createChannel()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.draft.selectedLibraries.isEmpty)
                        .focused($focusedButton, equals: .create)
                    }
                }
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

            let channel = Channel(
                id: channelID,
                name: finalName,
                libraryKey: primaryKey,
                libraryType: primaryType,
                scheduleAnchor: Date(),
                items: finalMedia,
                sourceLibraries: sources,
                options: Channel.Options(shuffle: draft.options.shuffle),
                provenance: .filters(draft)
            )

            let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
            let countsSummary = perLibraryCounts.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            AppLoggers.channel.info(
                "event=builder.compile.ok perLibCounts=\(countsSummary, privacy: .public) total=\(channel.items.count) elapsedMs=\(elapsed)"
            )

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
