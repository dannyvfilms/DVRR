//
//  PlexFilterCatalog.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

actor PlexFilterCatalog {
    private struct CacheKey: Hashable {
        let libraryID: String
        let field: FilterField
    }

    private let plexService: PlexService
    private let queryBuilder: PlexQueryBuilder
    private var optionCache: [CacheKey: [FilterOption]] = [:]
    nonisolated let supportedFields: Set<FilterField>

    init(
        plexService: PlexService,
        queryBuilder: PlexQueryBuilder,
        supportedFields: Set<FilterField> = [
            .title,
            .showTitle,
            .studio,
            .network,
            .genre,
            .country,
            .contentRating,
            .year,
            .decade,
            .rating,
            .audienceRating,
            .plays,
            .unwatched,
            .inProgress,
            .dateAdded,
            .dateViewed,
            .dateReleased,
            .episodeAirDate,
            .lastWatched,
            .resolution,
            .audioLanguage,
            .subtitleLanguage,
            .actor,
            .director,
            .writer,
            .duration
        ]
    ) {
        self.plexService = plexService
        self.queryBuilder = queryBuilder
        self.supportedFields = supportedFields
    }

    nonisolated func availableFields(for library: PlexLibrary) -> [FilterField] {
        let scope = FilterMediaScope(type: library.type)
        return supportedFields
            .filter { $0.applies(to: scope) }
            .sorted { $0.displayName < $1.displayName }
    }

    func options(
        for field: FilterField,
        in library: PlexLibrary
    ) async throws -> [FilterOption] {
        let cacheKey = CacheKey(libraryID: library.uuid, field: field)
        if let cached = optionCache[cacheKey] {
            return cached
        }

        let resolved: [FilterOption]
        switch field.valueKind {
        case .boolean:
            resolved = [
                FilterOption(value: "true", displayName: "Yes"),
                FilterOption(value: "false", displayName: "No")
            ]
        case .enumMulti, .enumSingle:
            resolved = try await enumerateOptions(for: field, library: library)
        default:
            resolved = []
        }

        optionCache[cacheKey] = resolved
        return resolved
    }
}

private extension PlexFilterCatalog {
    func enumerateOptions(
        for field: FilterField,
        library: PlexLibrary
    ) async throws -> [FilterOption] {
        // Use direct Plex API call instead of queryBuilder to avoid blocking
        let items = try await plexService.fetchLibraryItems(
            for: library,
            mediaType: library.type,
            limit: 600
        )
        var accumulator: [String: Int] = [:]

        for item in items {
            let values = FilterFieldResolver.stringValues(field, from: item)
            for value in values where !value.isEmpty {
                accumulator[value, default: 0] += 1
            }
        }

        return accumulator
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .map { key, count in
                FilterOption(value: key, displayName: key, count: count)
            }
    }
}
