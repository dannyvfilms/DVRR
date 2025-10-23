//
//  ChannelDraft.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

/// Captures the in-progress channel definition while the builder wizard is active.
struct ChannelDraft: Codable, Hashable {
    struct Options: Codable, Hashable {
        var shuffle: Bool = false
    }

    var id: UUID = UUID()
    var name: String = ""
    var selectedLibraries: [LibraryFilterSpec.LibraryRef]
    var perLibrarySpecs: [LibraryFilterSpec]
    var sort: SortDescriptor
    var options: Options

    init(
        name: String = "",
        selectedLibraries: [LibraryFilterSpec.LibraryRef] = [],
        perLibrarySpecs: [LibraryFilterSpec] = [],
        sort: SortDescriptor = SortDescriptor(key: .title),
        options: Options = Options()
    ) {
        self.name = name
        self.selectedLibraries = selectedLibraries
        self.perLibrarySpecs = perLibrarySpecs
        self.sort = sort
        self.options = options
    }

    mutating func updateSpec(_ spec: LibraryFilterSpec) {
        if let index = perLibrarySpecs.firstIndex(where: { $0.id == spec.id }) {
            perLibrarySpecs[index] = spec
        } else {
            perLibrarySpecs.append(spec)
        }
    }

    func spec(for ref: LibraryFilterSpec.LibraryRef) -> LibraryFilterSpec? {
        perLibrarySpecs.first { $0.id == ref.id }
    }

    mutating func ensureSpecs() {
        let knownIDs = Set(perLibrarySpecs.map(\.id))
        for ref in selectedLibraries where !knownIDs.contains(ref.id) {
            let spec = LibraryFilterSpec(reference: ref, rootGroup: FilterGroup())
            perLibrarySpecs.append(spec)
        }
    }

    mutating func removeSpec(for libraryID: String) {
        perLibrarySpecs.removeAll { $0.id == libraryID }
    }

    func primaryMediaType() -> PlexMediaType? {
        guard let first = selectedLibraries.first else { return nil }
        // Normalize TV shows to episodes for channel compilation
        switch first.type {
        case .show:
            return .episode
        default:
            return first.type
        }
    }
}
