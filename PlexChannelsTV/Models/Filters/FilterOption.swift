//
//  FilterOption.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation

struct FilterOption: Codable, Hashable, Identifiable {
    var id: String { value }
    let value: String
    let displayName: String
    let count: Int?

    init(value: String, displayName: String? = nil, count: Int? = nil) {
        self.value = value
        self.displayName = displayName ?? value
        self.count = count
    }
}
