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
        case sort
        case review
    }

    struct CountState: Equatable {
        var isLoading = false
        var total: Int?
        var approximate = false
    }

    @Published var step: Step = .libraries {
        didSet {
            AppLoggers.channel.info("event=builder.view.show step=\(self.step.telemetryValue, privacy: .public)")
        }
    }
    @Published var draft: ChannelDraft = ChannelDraft()
    @Published var counts: [String: CountState] = [:]
    @Published var errorMessage: String?

    let plexService: PlexService
    let channelStore: ChannelStore
    let queryBuilder: PlexQueryBuilder
    let filterCatalog: PlexFilterCatalog
    let sortCatalog = PlexSortCatalog()
    let allLibraries: [PlexLibrary]

    private var allowedType: PlexMediaType?
    private var countTasks: [String: Task<Void, Never>] = [:]

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

    func goToNextRulesStep(currentIndex: Int) {
        let nextIndex = currentIndex + 1
        if nextIndex < draft.selectedLibraries.count {
            step = .rules(index: nextIndex)
            preloadCountIfNeeded(forIndex: nextIndex)
        } else {
            step = .sort
            ensureSortDefaults()
        }
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
        case .sort:
            if draft.selectedLibraries.isEmpty {
                self.step = .libraries
            } else {
                self.step = .rules(index: draft.selectedLibraries.count - 1)
            }
        case .review:
            self.step = .sort
        }
    }

    func advanceFromSort() {
        step = .review
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
        countTasks[id]?.cancel()
        let current = counts[id] ?? CountState()
        counts[id] = CountState(isLoading: true, total: current.total, approximate: current.approximate)
        AppLoggers.channel.info("event=builder.count.start libraryID=\(id, privacy: .public)")

        countTasks[id] = Task { [weak self] in
            let startedAt = Date()
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            guard let library = self.library(for: ref.id) else { return }
            do {
                let total = try await self.queryBuilder.count(library: library, using: group)
                await MainActor.run {
                    self.counts[id] = CountState(isLoading: false, total: total, approximate: false)
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLoggers.channel.info("event=builder.count.ok libraryID=\(id, privacy: .public) total=\(total) elapsedMs=\(elapsed) remote=false")
            } catch {
                await MainActor.run {
                    self.counts[id] = CountState(isLoading: false, total: nil, approximate: false)
                    self.errorMessage = error.localizedDescription
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                AppLoggers.channel.error("event=builder.count.fail libraryID=\(id, privacy: .public) elapsedMs=\(elapsed) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func totalItemCountEstimate() -> Int? {
        let totals = draft.selectedLibraries.compactMap { counts[$0.id]?.total }
        guard totals.count == draft.selectedLibraries.count else { return nil }
        return totals.reduce(0, +)
    }

    func library(for id: String) -> PlexLibrary? {
        allLibraries.first { $0.uuid == id }
    }

    func availableFields(for library: PlexLibrary) -> [FilterField] {
        filterCatalog.availableFields(for: library)
    }

    func ensureSortDefaults() {
        guard let first = draft.selectedLibraries.first, let library = library(for: first.id) else { return }
        draft.sort = sortCatalog.defaultDescriptor(for: library)
    }

    func normalizedType(for type: PlexMediaType) -> PlexMediaType {
        switch type {
        case .show:
            return .episode
        default:
            return type
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
        case .sort:
            return "sort"
        case .review:
            return "review"
        }
    }
}
