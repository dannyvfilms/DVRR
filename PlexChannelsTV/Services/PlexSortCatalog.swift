//
//  PlexSortCatalog.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

struct PlexSortCatalog {
    func availableSorts(for library: PlexLibrary) -> [SortDescriptor.SortKey] {
        let mediaType = normalizedType(for: library.type)
        return SortDescriptor.SortKey.defaults(for: mediaType)
    }

    func defaultDescriptor(for library: PlexLibrary) -> SortDescriptor {
        SortDescriptor.default(for: normalizedType(for: library.type))
    }

    func token(
        for descriptor: SortDescriptor,
        library: PlexLibrary
    ) -> String? {
        token(for: descriptor, mediaType: normalizedType(for: library.type))
    }
}

private extension PlexSortCatalog {
    func token(
        for descriptor: SortDescriptor,
        mediaType: PlexMediaType
    ) -> String? {
        guard let keyToken = keyToken(for: descriptor.key, mediaType: mediaType) else {
            return nil
        }
        guard descriptor.key != .random else {
            return "random"
        }
        let suffix = descriptor.order == .ascending ? "asc" : "desc"
        return "\(keyToken):\(suffix)"
    }

    func keyToken(
        for key: SortDescriptor.SortKey,
        mediaType: PlexMediaType
    ) -> String? {
        switch key {
        case .title:
            return "titleSort"
        case .showTitle:
            return mediaType == .episode ? "grandparentTitleSort" : "titleSort"
        case .year:
            return "year"
        case .originallyAvailableAt, .episodeAirDate:
            return "originallyAvailableAt"
        case .rating, .criticRating:
            return "rating"
        case .audienceRating:
            return "audienceRating"
        case .contentRating:
            return "contentRating"
        case .addedAt:
            return "addedAt"
        case .lastViewedAt:
            return "lastViewedAt"
        case .viewCount:
            return "viewCount"
        case .unviewed:
            return "unviewed"
        case .random:
            return "random"
        }
    }

    func normalizedType(for type: PlexMediaType) -> PlexMediaType {
        switch type {
        case .show:
            return .episode
        default:
            return type
        }
    }
}
