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

    private enum SeedChannel: String, CaseIterable {
        case moviesMix = "seed.movies.mix"
        case moviesAction = "seed.movies.action"
        case tvMix = "seed.tv.mix"
        case tvComedy = "seed.tv.comedy"
    }

    init(
        plexService: PlexService,
        channelStore: ChannelStore,
        defaults: UserDefaults = .standard
    ) {
        self.plexService = plexService
        self.channelStore = channelStore
        self.defaults = defaults
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
                if pendingSeeds.contains(SeedChannel.moviesMix.rawValue),
                   try await seedMoviesMix(from: movieLibraries) {
                    seededAny = true
                }
                if pendingSeeds.contains(SeedChannel.moviesAction.rawValue),
                   try await seedMoviesAction(from: movieLibraries) {
                    seededAny = true
                }
            }

            if !showLibraries.isEmpty {
                if pendingSeeds.contains(SeedChannel.tvMix.rawValue),
                   try await seedTVMix(from: showLibraries) {
                    seededAny = true
                }
                if pendingSeeds.contains(SeedChannel.tvComedy.rawValue),
                   try await seedTVComedy(from: showLibraries) {
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

    private func fetchItems(from libraries: [PlexLibrary], limitPerLibrary: Int = 800) async throws -> [PlexMediaItem] {
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
                let items = try await plexService.fetchLibraryItems(
                    for: library,
                    mediaType: targetType,
                    limit: limitPerLibrary
                )
                allItems.append(contentsOf: items)
                print("[ChannelSeeder] Fetched \(items.count) items from \(library.title ?? "library")")
            } catch {
                print("[ChannelSeeder] Failed to fetch items for \(library.title ?? "library"): \(error)")
            }
        }
        return allItems
    }

    private func seedMoviesMix(from libraries: [PlexLibrary]) async throws -> Bool {
        let items = try await fetchItems(from: libraries)
        let medias = items.compactMap(Channel.Media.from)
        guard !medias.isEmpty else { return false }

        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }

        let channel = Channel(
            name: "Movies — Mix",
            libraryKey: "seed.movies.mix",
            libraryType: .movie,
            scheduleAnchor: Date(),
            items: medias.shuffled(),
            sourceLibraries: sources,
            options: Channel.Options(shuffle: true),
            provenance: .seed(identifier: SeedChannel.moviesMix.rawValue)
        )

        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created Movies — Mix with \(medias.count) items")
        }
        return appended
    }

    private func seedMoviesAction(from libraries: [PlexLibrary]) async throws -> Bool {
        let items = try await fetchItems(from: libraries)
        let filtered = items.filter { media in
            media.genres.contains(where: { $0.tag.localizedCaseInsensitiveContains("action") })
        }
        let medias = filtered.compactMap(Channel.Media.from)
        guard !medias.isEmpty else { return false }

        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }

        let channel = Channel(
            name: "Movies — Action",
            libraryKey: "seed.movies.action",
            libraryType: .movie,
            scheduleAnchor: Date(),
            items: medias.shuffled(),
            sourceLibraries: sources,
            options: Channel.Options(shuffle: true),
            provenance: .seed(identifier: SeedChannel.moviesAction.rawValue)
        )

        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created Movies — Action with \(medias.count) items")
        }
        return appended
    }

    private func seedTVMix(from libraries: [PlexLibrary]) async throws -> Bool {
        let items = try await fetchItems(from: libraries)
        let episodes = items.filter { $0.type == .episode }
        let medias = episodes.compactMap(Channel.Media.from)
        guard !medias.isEmpty else { return false }

        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }

        let channel = Channel(
            name: "TV — Mix",
            libraryKey: "seed.tv.mix",
            libraryType: .episode,
            scheduleAnchor: Date(),
            items: medias.shuffled(),
            sourceLibraries: sources,
            options: Channel.Options(shuffle: true),
            provenance: .seed(identifier: SeedChannel.tvMix.rawValue)
        )

        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created TV — Mix with \(medias.count) items")
        }
        return appended
    }

    private func seedTVComedy(from libraries: [PlexLibrary]) async throws -> Bool {
        let items = try await fetchItems(from: libraries)
        let comedies = items.filter { item in
            item.genres.contains(where: { $0.tag.localizedCaseInsensitiveContains("comedy") })
        }
        let medias = comedies.compactMap(Channel.Media.from)
        guard !medias.isEmpty else { return false }

        let sources = libraries.map { library in
            Channel.SourceLibrary(
                id: library.uuid,
                key: library.key,
                title: library.title,
                type: library.type
            )
        }

        let channel = Channel(
            name: "TV — Comedy",
            libraryKey: "seed.tv.comedy",
            libraryType: .episode,
            scheduleAnchor: Date(),
            items: medias.shuffled(),
            sourceLibraries: sources,
            options: Channel.Options(shuffle: true),
            provenance: .seed(identifier: SeedChannel.tvComedy.rawValue)
        )

        let appended = await channelStore.addChannel(channel)
        if appended {
            print("[ChannelSeeder] Created TV — Comedy with \(medias.count) items")
        }
        return appended
    }
}
