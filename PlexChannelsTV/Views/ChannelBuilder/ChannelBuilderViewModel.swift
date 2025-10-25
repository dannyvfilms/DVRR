//
//  ChannelBuilderViewModel.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import SwiftUI
import PlexKit

@MainActor
final class ChannelBuilderViewModel: ObservableObject {
    enum Step: Equatable {
        case libraries
        case rules(index: Int)
    }

    struct CountState: Equatable {
        var isLoading = false
        var total: Int?
        var approximate = false
        var progressCount: Int? = nil
    }

    @Published var step: Step = .libraries {
        didSet {
            AppLoggers.channel.info("event=builder.view.show step=\(self.step.telemetryValue, privacy: .public)")
        }
    }
    @Published var draft: ChannelDraft = ChannelDraft()
    @Published var counts: [String: CountState] = [:]
    @Published var errorMessage: String?
    @Published var previewUpdateTrigger = UUID()

    let plexService: PlexService
    let channelStore: ChannelStore
    let queryBuilder: PlexQueryBuilder
    let filterCatalog: PlexFilterCatalog
    let sortCatalog = PlexSortCatalog()
    let allLibraries: [PlexLibrary]

    private var allowedType: PlexMediaType?
    private var countTasks: [String: Task<Void, Never>] = [:]
    private var isMenuOpen = false

    init(
        plexService: PlexService,
        channelStore: ChannelStore,
        libraries: [PlexLibrary]
    ) {
        self.plexService = plexService
        self.channelStore = channelStore
        self.allLibraries = libraries.sorted { ($0.title ?? "") < ($1.title ?? "") }
        self.queryBuilder = PlexQueryBuilder(plexService: plexService)
        self.filterCatalog = PlexFilterCatalog(plexService: plexService, queryBuilder: queryBuilder)
        
        // Set up progress callback
        Task {
            await queryBuilder.setProgressCallback { [weak self] libraryID, count in
                Task { @MainActor in
                    self?.updateCountProgress(for: libraryID, count: count)
                }
            }
        }
        
        AppLoggers.channel.info("event=builder.view.show step=\(self.step.telemetryValue, privacy: .public)")
    }

    var selectedLibraryRefs: [LibraryFilterSpec.LibraryRef] {
        draft.selectedLibraries
    }

    func toggleLibrary(_ library: PlexLibrary) {
        let normalized = normalizedType(for: library.type)
        
        AppLoggers.channel.info("event=builder.toggleLibrary libraryID=\(library.uuid, privacy: .public) libraryTitle=\(library.title ?? "unknown", privacy: .public) type=\(normalized.rawValue, privacy: .public)")

        if draft.selectedLibraries.contains(where: { $0.id == library.uuid }) {
            AppLoggers.channel.info("event=builder.toggleLibrary.remove libraryID=\(library.uuid, privacy: .public)")
            draft.selectedLibraries.removeAll { $0.id == library.uuid }
            draft.removeSpec(for: library.uuid)
            counts[library.uuid] = nil
            if draft.selectedLibraries.isEmpty {
                allowedType = nil
            }
            updateSuggestedNameIfNeeded()
            return
        }

        if let allowedType, allowedType != normalized {
            AppLoggers.channel.warning("event=builder.toggleLibrary.blocked reason=typeMismatch allowedType=\(allowedType.rawValue, privacy: .public) attemptedType=\(normalized.rawValue, privacy: .public)")
            errorMessage = "You can only mix libraries of the same media type."
            return
        }

        allowedType = normalized

        let ref = LibraryFilterSpec.LibraryRef(
            id: library.uuid,
            key: library.key,
            title: library.title,
            type: normalized
        )

        draft.selectedLibraries.append(ref)
        draft.ensureSpecs()
        
        AppLoggers.channel.info("event=builder.toggleLibrary.add libraryID=\(library.uuid, privacy: .public) totalSelected=\(self.draft.selectedLibraries.count)")

        if draft.selectedLibraries.count == 1 {
            draft.sort = sortCatalog.defaultDescriptor(for: library)
        }

        updateSuggestedNameIfNeeded()
    }

    func proceedFromLibraries() {
        AppLoggers.channel.info("event=builder.proceedFromLibraries selectedCount=\(self.draft.selectedLibraries.count)")
        draft.ensureSpecs()
        guard !draft.selectedLibraries.isEmpty else {
            AppLoggers.channel.warning("event=builder.proceedFromLibraries.blocked reason=noLibrariesSelected")
            return
        }
        AppLoggers.channel.info("event=builder.proceedFromLibraries.advancing toRulesIndex=0")
        step = .rules(index: 0)
        preloadCountIfNeeded(forIndex: 0)
    }

    @discardableResult
    func goToNextRulesStep(currentIndex: Int) -> Bool {
        let nextIndex = currentIndex + 1
        if nextIndex < draft.selectedLibraries.count {
            step = .rules(index: nextIndex)
            preloadCountIfNeeded(forIndex: nextIndex)
            return true
        }
        return false
    }

    func goBack(from step: Step) {
        switch step {
        case .libraries:
            break
        case .rules(let index):
            if index == 0 {
                self.step = .libraries
            } else {
                self.step = .rules(index: max(0, index - 1))
            }
        }
    }

    func spec(for ref: LibraryFilterSpec.LibraryRef) -> LibraryFilterSpec {
        if let existing = draft.perLibrarySpecs.first(where: { $0.id == ref.id }) {
            return existing
        }
        let spec = LibraryFilterSpec(reference: ref, rootGroup: FilterGroup())
        draft.perLibrarySpecs.append(spec)
        return spec
    }

    func updateSpec(_ spec: LibraryFilterSpec) {
        draft.updateSpec(spec)
        scheduleCountUpdate(for: spec.reference, group: spec.rootGroup)
    }

    func binding(for ref: LibraryFilterSpec.LibraryRef) -> Binding<LibraryFilterSpec> {
        Binding(
            get: { self.spec(for: ref) },
            set: { newValue in
                self.draft.updateSpec(newValue)
            }
        )
    }

    func preloadCountIfNeeded(forIndex index: Int) {
        guard draft.selectedLibraries.indices.contains(index) else { return }
        let ref = draft.selectedLibraries[index]
        let spec = self.spec(for: ref)
        scheduleCountUpdate(for: ref, group: spec.rootGroup)
    }

    func scheduleCountUpdate(for ref: LibraryFilterSpec.LibraryRef, group: FilterGroup) {
        let id = ref.id
        
        // Don't cancel ongoing tasks - let them complete and use cached results
        // This prevents CancellationError during long TV show fetches
        if countTasks[id] != nil {
            AppLoggers.channel.info("event=builder.count.skip libraryID=\(id, privacy: .public) reason=ongoingFetch")
            return
        }
        
        let current = counts[id] ?? CountState()
        counts[id] = CountState(isLoading: true, total: current.total, approximate: current.approximate)
        AppLoggers.channel.info("event=builder.count.start libraryID=\(id, privacy: .public)")

        countTasks[id] = Task { [weak self] in
            let startedAt = Date()
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 second debounce
            guard let self, !Task.isCancelled else { return }
            guard let library = self.library(for: ref.id) else { return }
            do {
                let total = try await self.queryBuilder.count(library: library, using: group)
                await MainActor.run {
                    // Don't update final count if a menu is open to prevent UI interference
                    if self.isMenuOpen {
                        AppLoggers.channel.info("event=builder.count.skipped libraryID=\(id, privacy: .public) reason=menuOpen")
                        // Clear the task so new operations can start
                        self.countTasks[id] = nil
                        return
                    }
                    
                    self.counts[id] = CountState(isLoading: false, total: total, approximate: false)
                    // Trigger preview update after count completes
                    self.notifyPreviewUpdateNeeded()
                    // Clear the task so new operations can start
                    self.countTasks[id] = nil
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLoggers.channel.info("event=builder.count.ok libraryID=\(id, privacy: .public) total=\(total) elapsedMs=\(elapsed) remote=false")
            } catch {
                await MainActor.run {
                    // Don't update final count if a menu is open to prevent UI interference
                    if self.isMenuOpen {
                        AppLoggers.channel.info("event=builder.count.skipped libraryID=\(id, privacy: .public) reason=menuOpen")
                        // Clear the task so new operations can start
                        self.countTasks[id] = nil
                        return
                    }
                    
                    self.counts[id] = CountState(isLoading: false, total: nil, approximate: false)
                    self.errorMessage = error.localizedDescription
                    // Clear the task so new operations can start
                    self.countTasks[id] = nil
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLoggers.channel.error("event=builder.count.fail libraryID=\(id, privacy: .public) elapsedMs=\(elapsed) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func fetchPreviewMedia(limit: Int = 20) async -> [Channel.Media] {
        let descriptor = draft.sort
        let shuffle = draft.options.shuffle
        let serverSort = descriptor.key == .random ? nil : descriptor

        var combinedMedia: [Channel.Media] = []
        var seenIDs = Set<String>()
        
        for ref in draft.selectedLibraries {
            guard let library = library(for: ref.id) else { continue }
            let spec = spec(for: ref)
            do {
                let mediaItems = try await queryBuilder.buildChannelMedia(
                    library: library,
                    using: spec.rootGroup,
                    sort: serverSort,
                    limit: limit
                )
                for media in mediaItems where seenIDs.insert(media.id).inserted {
                    combinedMedia.append(media)
                }
            } catch {
                AppLoggers.channel.error("event=builder.preview.fail libraryID=\(ref.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        
        var preview = combinedMedia

        if descriptor.key != .random && !shuffle {
            preview = preview.sorted(using: descriptor)
        }

        if descriptor.key == .random || shuffle {
            var generator = SeededRandomNumberGenerator(seed: deterministicSeed(for: draft.id))
            preview.shuffle(using: &generator)
        }

        return Array(preview.prefix(limit))
    }

    func library(for id: String) -> PlexLibrary? {
        allLibraries.first { $0.uuid == id }
    }

    func availableFields(for library: PlexLibrary) -> [FilterField] {
        filterCatalog.availableFields(for: library)
    }

    func normalizedType(for type: PlexMediaType) -> PlexMediaType {
        switch type {
        case .show:
            return .episode
        default:
            return type
        }
    }

    private func deterministicSeed(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { buffer in
            let lower = buffer.load(as: UInt64.self)
            let upper = buffer.baseAddress!.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee
            return UInt64(littleEndian: lower) ^ UInt64(littleEndian: upper)
        }
    }

    private func notifyPreviewUpdateNeeded() {
        previewUpdateTrigger = UUID()
    }

    func setMenuOpen(_ isOpen: Bool) {
        isMenuOpen = isOpen
        AppLoggers.channel.info("event=builder.menu.state isOpen=\(isOpen)")
    }
    
    private func updateCountProgress(for libraryID: String, count: Int) {
        // Don't update progress if a menu is open to prevent navigation stuttering
        if isMenuOpen {
            AppLoggers.channel.info("event=builder.progress.skipped libraryID=\(libraryID, privacy: .public) reason=menuOpen")
            return
        }
        
        if let current = counts[libraryID], current.isLoading {
            counts[libraryID] = CountState(
                isLoading: true,
                total: current.total,
                approximate: current.approximate,
                progressCount: count
            )
        }
    }

    private func updateSuggestedNameIfNeeded() {
        guard draft.name.isEmpty else { return }
        if draft.selectedLibraries.count == 1, let title = draft.selectedLibraries.first?.title, !title.isEmpty {
            draft.name = title
        } else if let type = draft.primaryMediaType() {
            switch type {
            case .movie:
                draft.name = "Movies — Mix"
            case .episode:
                draft.name = "TV — Mix"
            default:
                draft.name = "Channel"
            }
        } else {
            draft.name = "Channel"
        }
    }
}

private extension ChannelBuilderViewModel.Step {
    var telemetryValue: String {
        switch self {
        case .libraries:
            return "libraries"
        case .rules:
            return "rules"
        }
    }
}
