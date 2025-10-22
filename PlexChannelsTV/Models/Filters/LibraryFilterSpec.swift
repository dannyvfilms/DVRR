//
//  LibraryFilterSpec.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

/// Captures the filter tree applied to a specific library section.
struct LibraryFilterSpec: Identifiable, Codable, Hashable {
    struct LibraryRef: Codable, Hashable {
        var id: String
        var key: String
        var title: String?
        var type: PlexMediaType
    }

    var id: String { reference.id }
    var reference: LibraryRef
    var rootGroup: FilterGroup

    init(
        reference: LibraryRef,
        rootGroup: FilterGroup
    ) {
        self.reference = reference
        self.rootGroup = rootGroup
    }

    init(
        library: PlexLibrary,
        rootGroup: FilterGroup = FilterGroup()
    ) {
        let ref = LibraryRef(
            id: library.uuid,
            key: library.key,
            title: library.title,
            type: library.type
        )
        self.init(reference: ref, rootGroup: rootGroup)
    }
}
