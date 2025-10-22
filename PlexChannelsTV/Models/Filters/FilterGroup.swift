//
//  FilterGroup.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation

/// Nested rule group tree mirroring Plex's advanced filters.
struct FilterGroup: Identifiable, Codable, Hashable {
    enum Mode: String, Codable, Hashable, CaseIterable, Identifiable {
        case all
        case any

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: return "Match All"
            case .any: return "Match Any"
            }
        }
    }

    let id: UUID
    var mode: Mode
    var rules: [FilterRule]
    var groups: [FilterGroup]

    init(
        id: UUID = UUID(),
        mode: Mode = .all,
        rules: [FilterRule] = [],
        groups: [FilterGroup] = []
    ) {
        self.id = id
        self.mode = mode
        self.rules = rules
        self.groups = groups
    }

    var isEmpty: Bool {
        rules.isEmpty && groups.allSatisfy(\.isEmpty)
    }

    mutating func appendRule(_ rule: FilterRule) {
        rules.append(rule)
    }

    mutating func appendGroup(_ group: FilterGroup) {
        groups.append(group)
    }
}
