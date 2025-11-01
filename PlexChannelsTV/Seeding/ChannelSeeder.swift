//
//  ChannelSeeder.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation
import PlexKit

final class ChannelSeeder {
    private let plexService: PlexService
    private let channelStore: ChannelStore
    private let defaults: UserDefaults
    private let seedKey = "channelSeeder.didSeedDefaults"
    private let queryBuilder: PlexQueryBuilder

    private enum SeedChannel: String, CaseIterable {
        case freshFinds = "seed.movies.freshFinds"
        case rewatchFactory = "seed.movies.rewatchFactory"
        case familyFavorites = "seed.movies.familyFavorites"
        case catchUpCorner = "seed.tv.catchUpCorner"
        case recentRoulette = "seed.tv.recentRoulette"
    }

    init(
        plexService: PlexService,
        channelStore: ChannelStore,
        defaults: UserDefaults = .standard
    ) {
        self.plexService = plexService
        self.channelStore = channelStore
        self.defaults = defaults
        self.queryBuilder = PlexQueryBuilder(plexService: plexService)
    }

    func seedIfNeeded(libraries: [PlexLibrary]) async {
        let existingKeys = await MainActor.run {
            Set(channelStore.channels.map(\.libraryKey))
        }

        let expectedKeys = Set(SeedChannel.allCases.map(\.rawValue))
        let hasSeededBefore = defaults.bool(forKey: seedKey)

        var pendingSeeds: Set<String>
        if hasSeededBefore {
            pendingSeeds = expectedKeys.subtracting(existingKeys)
            if existingKeys.isEmpty {
                pendingSeeds = expectedKeys
            }
        } else {
            pendingSeeds = expectedKeys
        }

        guard !pendingSeeds.isEmpty else { return }

        defaults.set(false, forKey: seedKey)

        print("[ChannelSeeder] Starting default channel seeding…")

        do {
            let movieLibraries = libraries.filter { $0.type == .movie }
            let showLibraries = libraries.filter { $0.type == .show || $0.type == .episode }

            var seededAny = false

            if !movieLibraries.isEmpty {
                if pendingSeeds.contains(SeedChannel.freshFinds.rawValue),
                   try await seedFreshFinds(from: movieLibraries) {
                    seededAny = true
                }
                if pendingSeeds.contains(SeedChannel.rewatchFactory.rawValue),
                   try await seedRewatchFactory(from: movieLibraries) {
                    seededAny = true
                }
                if pendingSeeds.contains(SeedChannel.familyFavorites.rawValue),
                   try await seedFamilyFavorites(from: movieLibraries) {
                    seededAny = true
                }
            }

            if !showLibraries.isEmpty {
                if pendingSeeds.contains(SeedChannel.catchUpCorner.rawValue),
                   try await seedCatchUpCorner(from: showLibraries) {
                    seededAny = true
                }
                if pendingSeeds.contains(SeedChannel.recentRoulette.rawValue),
                   try await seedRecentRoulette(from: showLibraries) {
                    seededAny = true
                }
            }

            if seededAny {
                defaults.set(true, forKey: seedKey)
                print("[ChannelSeeder] Default channel seeding completed.")
            } else {
                print("[ChannelSeeder] No default channels created (insufficient content).")
            }
        } catch {
            print("[ChannelSeeder] Failed to seed default channels: \(error)")
        }
    }

    private func fetchItems(from libraries: [PlexLibrary], limitPerLibrary: Int? = nil) async throws -> [PlexMediaItem] {
        var allItems: [PlexMediaItem] = []
        for library in libraries {
            do {
                let targetType: PlexMediaType = {
                    switch library.type {
                    case .show:
                        return .episode
                    default:
                        return library.type
                    }
                }()
                
                // Use different limits based on library type
                let effectiveLimit: Int = {
                    if let customLimit = limitPerLibrary {
                        return customLimit
                    }
                    // For movies, allow up to 10,000 items (no practical limit)
                    // For TV shows, use 800 to avoid overwhelming the system
                    switch library.type {
                    case .movie:
                        return 10000
                    case .show, .episode:
                        return 800
                    default:
                        return 800
                    }
                }()
                
                let items = try await plexService.fetchLibraryItems(
                    for: library,
                    mediaType: targetType,
                    limit: effectiveLimit
                )
                allItems.append(contentsOf: items)
                print("[ChannelSeeder] Fetched \(items.count) items from \(library.title ?? "library")")
            } catch {
                print("[ChannelSeeder] Failed to fetch items for \(library.title ?? "library"): \(error)")
            }
        }
        return allItems
    }

    private func seedFreshFinds(from libraries: [PlexLibrary]) async throws -> Bool {
        // Fresh Finds: Date Released in the last 90 days AND unwatched is true
        let filterGroup = FilterGroup(
            mode: .all,
            rules: [
                FilterRule(
                    field: .dateReleased,
                    op: .inTheLast,
                    value: .relativeDate(.last90Days)
                ),
                FilterRule(
                    field: .unwatched,
                    op: .equals,
                    value: .boolean(true)
                )
            ]
        )
        
        return try await createChannelFromFilters(
            name: "Fresh Finds",
            libraryKey: SeedChannel.freshFinds.rawValue,
            libraries: libraries,
            filterGroup: filterGroup
        )
    }

    private func seedRewatchFactory(from libraries: [PlexLibrary]) async throws -> Bool {
        // Rewatch Factory: Last watched in the last 2 years AND last watched not in the last 3 months
        let filterGroup = FilterGroup(
            mode: .all,
            rules: [
                FilterRule(
                    field: .lastWatched,
                    op: .inTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 2, unit: .years))
                ),
                FilterRule(
                    field: .lastWatched,
                    op: .notInTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 3, unit: .months))
                )
            ]
        )
        
        return try await createChannelFromFilters(
            name: "Rewatch Factory",
            libraryKey: SeedChannel.rewatchFactory.rawValue,
            libraries: libraries,
            filterGroup: filterGroup
        )
    }

    private func seedFamilyFavorites(from libraries: [PlexLibrary]) async throws -> Bool {
        // Family Favorites: Last watched not in the last 2 years AND content rating is not R AND content rating is not PG-13
        let filterGroup = FilterGroup(
            mode: .all,
            rules: [
                FilterRule(
                    field: .lastWatched,
                    op: .notInTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 2, unit: .years))
                ),
                FilterRule(
                    field: .contentRating,
                    op: .notEquals,
                    value: .enumCase("R")
                ),
                FilterRule(
                    field: .contentRating,
                    op: .notEquals,
                    value: .enumCase("PG-13")
                )
            ]
        )
        
        return try await createChannelFromFilters(
            name: "Family Favorites",
            libraryKey: SeedChannel.familyFavorites.rawValue,
            libraries: libraries,
            filterGroup: filterGroup
        )
    }
    
    private func createChannelFromFilters(
        name: String,
        libraryKey: String,
        libraries: [PlexLibrary],
        filterGroup: FilterGroup
    ) async throws -> Bool {
        var combinedMedia: [Channel.Media] = []
        var seenIDs = Set<String>()
        
        for library in libraries {
            let mediaItems = try await queryBuilder.buildChannelMedia(
                library: library,
                using: filterGroup,
                sort: nil, // Random sort - we'll shuffle manually
                limit: nil
            )
            for media in mediaItems where seenIDs.insert(media.id).inserted {
                combinedMedia.append(media)
            }
        }
        
        guard !combinedMedia.isEmpty else { return false }
        
        // Apply random sort using deterministic seed
        let channelID = UUID()
        var generator = SeededRandomNumberGenerator(seed: deterministicSeed(for: channelID))
        combinedMedia.shuffle(using: &generator)
        
        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }
        
        // Create draft so channel can be edited later
        let libraryRefs = libraries.map { library in
            LibraryFilterSpec.LibraryRef(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }
        let perLibrarySpecs = libraries.map { library in
            LibraryFilterSpec(
                reference: LibraryFilterSpec.LibraryRef(
                    id: library.uuid,
                    key: library.key,
                    title: library.title,
                    type: library.type
                ),
                rootGroup: filterGroup
            )
        }
        let draft = ChannelDraft(
            name: name,
            selectedLibraries: libraryRefs,
            perLibrarySpecs: perLibrarySpecs,
            sort: SortDescriptor(key: .random),
            options: ChannelDraft.Options(shuffle: true)
        )
        
        let channel = Channel(
            id: channelID,
            name: name,
            libraryKey: libraryKey,
            libraryType: .movie,
            scheduleAnchor: Date(),
            items: combinedMedia,
            sourceLibraries: sources,
            options: Channel.Options(shuffle: true),
            provenance: .filters(draft)
        )
        
        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created \(name) with \(combinedMedia.count) items")
        }
        return appended
    }
    
    private func deterministicSeed(for id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { buffer in
            let lower = buffer.load(as: UInt64.self)
            let upper = buffer.baseAddress!.advanced(by: 8).assumingMemoryBound(to: UInt64.self).pointee
            return UInt64(littleEndian: lower) ^ UInt64(littleEndian: upper)
        }
    }

    private func seedCatchUpCorner(from libraries: [PlexLibrary]) async throws -> Bool {
        // Catch-up Corner: Episode Unwatched is true, Show Last Watched is in the last 2 years, Episode Air Date is in the last 4 weeks
        let filterGroup = FilterGroup(
            mode: .all,
            rules: [
                // Show-level filter: Show Last Watched in the last 2 years
                FilterRule(
                    field: .showLastWatched,
                    op: .inTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 2, unit: .years))
                ),
                // Episode-level filters: Episode Unwatched and Episode Air Date in last 4 weeks
                FilterRule(
                    field: .unwatched,
                    op: .equals,
                    value: .boolean(true)
                ),
                FilterRule(
                    field: .episodeAirDate,
                    op: .inTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 4, unit: .weeks))
                )
            ]
        )
        
        let sortDescriptor = SortDescriptor(key: .episodeAirDate, order: .ascending)
        
        return try await createTVChannelFromFilters(
            name: "Catch-up Corner",
            libraryKey: SeedChannel.catchUpCorner.rawValue,
            libraries: libraries,
            filterGroup: filterGroup,
            sort: sortDescriptor
        )
    }

    private func seedRecentRoulette(from libraries: [PlexLibrary]) async throws -> Bool {
        // Recent Roulette: Episode Unwatched is true, Episode Air Date is in the last 1 year
        let filterGroup = FilterGroup(
            mode: .all,
            rules: [
                FilterRule(
                    field: .unwatched,
                    op: .equals,
                    value: .boolean(true)
                ),
                FilterRule(
                    field: .episodeAirDate,
                    op: .inTheLast,
                    value: .relativeDateSpec(RelativeDateSpec(value: 1, unit: .years))
                )
            ]
        )
        
        let sortDescriptor = SortDescriptor(key: .episodeAirDate, order: .ascending)
        
        return try await createTVChannelFromFilters(
            name: "Recent Roulette",
            libraryKey: SeedChannel.recentRoulette.rawValue,
            libraries: libraries,
            filterGroup: filterGroup,
            sort: sortDescriptor
        )
    }
    
    private func createTVChannelFromFilters(
        name: String,
        libraryKey: String,
        libraries: [PlexLibrary],
        filterGroup: FilterGroup,
        sort: SortDescriptor
    ) async throws -> Bool {
        var combinedMedia: [Channel.Media] = []
        var seenIDs = Set<String>()
        
        for library in libraries {
            let mediaItems = try await queryBuilder.buildChannelMedia(
                library: library,
                using: filterGroup,
                sort: sort,
                limit: nil
            )
            for media in mediaItems where seenIDs.insert(media.id).inserted {
                combinedMedia.append(media)
            }
        }
        
        guard !combinedMedia.isEmpty else { return false }
        
        // Apply sorting to combined results (queryBuilder may have sorted per-library)
        if sort.key != .random {
            combinedMedia = combinedMedia.sorted(using: sort)
        }
        
        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }
        
        // Create draft so channel can be edited later
        let libraryRefs = libraries.map { library in
            LibraryFilterSpec.LibraryRef(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }
        let perLibrarySpecs = libraries.map { library in
            LibraryFilterSpec(
                reference: LibraryFilterSpec.LibraryRef(
                    id: library.uuid,
                    key: library.key,
                    title: library.title,
                    type: library.type
                ),
                rootGroup: filterGroup
            )
        }
        let draft = ChannelDraft(
            name: name,
            selectedLibraries: libraryRefs,
            perLibrarySpecs: perLibrarySpecs,
            sort: sort,
            options: ChannelDraft.Options(shuffle: false)
        )
        
        let channel = Channel(
            id: UUID(),
            name: name,
            libraryKey: libraryKey,
            libraryType: .episode,
            scheduleAnchor: Date(),
            items: combinedMedia,
            sourceLibraries: sources,
            options: Channel.Options(shuffle: false),
            provenance: .filters(draft)
        )
        
        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created \(name) with \(combinedMedia.count) items")
        }
        return appended
    }
}
