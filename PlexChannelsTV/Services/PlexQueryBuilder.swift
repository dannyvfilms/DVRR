//
//  PlexQueryBuilder.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

actor PlexQueryBuilder {
    enum QueryError: Error {
        case unsupportedField(FilterField)
        case missingValue(FilterRule)
    }

    private let plexService: PlexService
    private let cacheStore: LibraryMediaCacheStore
    private var mediaCache: [String: LibraryMediaCacheStore.Entry] = [:]
    private var progressCallback: ((String, Int) -> Void)?
    private var activeFetches: Set<String> = []
    private var lastRefreshAttempt: [String: Date] = [:]

    private let movieRefreshInterval: TimeInterval = 60 * 60  // 1 hour

    init(
        plexService: PlexService,
        cacheStore: LibraryMediaCacheStore = .shared
    ) {
        self.plexService = plexService
        self.cacheStore = cacheStore
    }
    
    func setProgressCallback(_ callback: @escaping (String, Int) -> Void) {
        progressCallback = callback
    }

    private func preferredMediaType(for library: PlexLibrary) -> PlexMediaType {
        switch library.type {
        case .show:
            return .show  // For TV libraries, fetch shows first, then episodes
        default:
            return library.type
        }
    }

    func invalidateCache(for libraryID: String) {
        // Remove all cache entries for this library (both shows and episodes)
        let keysToRemove = mediaCache.keys.filter { $0.hasPrefix(libraryID) }
        for key in keysToRemove {
            let removed = mediaCache.removeValue(forKey: key)
            lastRefreshAttempt.removeValue(forKey: key)
            if let entry = removed {
                if entry.key.mediaType == .movie {
                    Task {
                        await cacheStore.removeEntry(for: entry.key)
                    }
                }
            }
        }
    }
    
    func invalidateAllCache() {
        mediaCache.removeAll()
        lastRefreshAttempt.removeAll()
    }
    
    func updateProgress(for libraryID: String, count: Int) {
        progressCallback?(libraryID, count)
    }

    func mediaSnapshot(for library: PlexLibrary, limit: Int? = nil, mediaType: PlexMediaType? = nil) async throws -> [PlexMediaItem] {
        let targetType = mediaType ?? preferredMediaType(for: library)
        let cacheKey = makeCacheKey(for: library, mediaType: targetType)
        let storeKey = makeStoreKey(for: library, mediaType: targetType)
        let useMemoryCache = limit == nil
        let useDiskCache = useMemoryCache && (targetType == .movie || targetType == .episode)
        let effectiveLimit = limit

        if useMemoryCache, let cachedEntry = mediaCache[cacheKey] {
            AppLoggers.channel.info("event=queryBuilder.snapshot.cache source=memory libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(cachedEntry.itemCount) limit=\(effectiveLimit ?? -1)")
            scheduleBackgroundRefreshIfNeeded(
                for: cachedEntry,
                library: library,
                targetType: targetType,
                cacheKey: cacheKey
            )
            return applyLimitIfNeeded(cachedEntry.items, limit: effectiveLimit)
        }

        if useDiskCache, let persistedEntry = await cacheStore.entry(for: storeKey) {
            mediaCache[cacheKey] = persistedEntry
            AppLoggers.channel.info("event=queryBuilder.snapshot.cache source=disk libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(persistedEntry.itemCount) limit=\(effectiveLimit ?? -1)")
            scheduleBackgroundRefreshIfNeeded(
                for: persistedEntry,
                library: library,
                targetType: targetType,
                cacheKey: cacheKey
            )
            return applyLimitIfNeeded(persistedEntry.items, limit: effectiveLimit)
        }

        let entry = try await fetchSnapshotFromNetwork(
            library: library,
            targetType: targetType,
            effectiveLimit: effectiveLimit,
            cacheKey: cacheKey,
            storeKey: storeKey,
            useMemoryCache: useMemoryCache,
            useDiskCache: useDiskCache
        )

        return applyLimitIfNeeded(entry.items, limit: effectiveLimit)
    }

    func count(
        library: PlexLibrary,
        using group: FilterGroup
    ) async throws -> Int {
        // For TV libraries, check if we have cached episodes first
        if library.type == .show {
            let episodeCacheKey = makeCacheKey(for: library, mediaType: .episode)
            let episodeStoreKey = makeStoreKey(for: library, mediaType: .episode)
            
            // Check if we have cached episodes
            if let cachedEpisodes = mediaCache[episodeCacheKey] {
                AppLoggers.channel.info("event=queryBuilder.count.cachedEpisodes libraryID=\(library.uuid, privacy: .public) itemCount=\(cachedEpisodes.itemCount)")
                guard !group.isEmpty else { return cachedEpisodes.itemCount }
                return cachedEpisodes.items.reduce(into: 0) { partial, item in
                    if matches(item, group: group) {
                        partial += 1
                    }
                }
            }
            
            // Check disk cache for episodes
            if let diskEpisodes = await cacheStore.entry(for: episodeStoreKey) {
                mediaCache[episodeCacheKey] = diskEpisodes
                AppLoggers.channel.info("event=queryBuilder.count.diskEpisodes libraryID=\(library.uuid, privacy: .public) itemCount=\(diskEpisodes.itemCount)")
                guard !group.isEmpty else { return diskEpisodes.itemCount }
                return diskEpisodes.items.reduce(into: 0) { partial, item in
                    if matches(item, group: group) {
                        partial += 1
                    }
                }
            }
            
            // No cached episodes, use two-step process to get episode counts
            let media = try await buildChannelMediaForTVShows(
                library: library,
                using: group,
                sort: nil,
                limit: nil
            )
            return media.count
        }
        
        // For movies, use standard approach with cached data
        let items = try await mediaSnapshot(for: library, limit: nil)
        AppLoggers.channel.info("event=queryBuilder.count.snapshot libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(items.count)")
        guard !group.isEmpty else { return items.count }
        return items.reduce(into: 0) { partial, item in
            if matches(item, group: group) {
                partial += 1
            }
        }
    }

    func fetchMedia(
        library: PlexLibrary,
        using group: FilterGroup,
        sort descriptor: SortDescriptor?,
        limit: Int? = nil
    ) async throws -> [PlexMediaItem] {
        // For TV libraries with show-level filters, use two-step process
        if library.type == .show && hasShowLevelFilters(group) {
            // For TV shows with show-level filters, we need to use the TV-specific logic
            // But we can't return Channel.Media from this method, so we'll handle this differently
            // For now, fall back to standard approach for TV shows with show-level filters
            AppLoggers.channel.info("event=queryBuilder.fetchMedia.tvShowWithFilters using standard approach")
        }
        
        // For movies, TV shows without show-level filters, or episode-only filtering, use standard approach
        // For TV libraries without show-level filters, we need episodes, not shows
        let targetType: PlexMediaType = {
            if library.type == .show && !hasShowLevelFilters(group) {
                return .episode  // For TV without show-level filters, get episodes directly
            }
            return preferredMediaType(for: library)  // Use the standard logic
        }()
        
        // Use cached data for filtering
        var items = try await mediaSnapshot(for: library, limit: nil, mediaType: targetType)
        if !group.isEmpty {
            items = items.filter { matches($0, group: group) }
        }
        if let descriptor {
            items = sort(items, using: descriptor)
        }
        if let limit, limit < items.count {
            return Array(items.prefix(limit))
        }
        return items
    }

    func fetchIdentifiers(
        library: PlexLibrary,
        using group: FilterGroup,
        sort descriptor: SortDescriptor?,
        limit: Int? = nil
    ) async throws -> [String] {
        let media = try await fetchMedia(
            library: library,
            using: group,
            sort: descriptor,
            limit: limit
        )
        return media.map(\.ratingKey)
    }

    func buildChannelMedia(
        library: PlexLibrary,
        using group: FilterGroup,
        sort descriptor: SortDescriptor?,
        limit: Int? = nil
    ) async throws -> [Channel.Media] {
        // For TV libraries, check if we have cached episodes first
        if library.type == .show {
            let episodeCacheKey = makeCacheKey(for: library, mediaType: .episode)
            let episodeStoreKey = makeStoreKey(for: library, mediaType: .episode)
            
            // Check if we have cached episodes in memory
            if let cachedEpisodes = mediaCache[episodeCacheKey] {
                AppLoggers.channel.info("event=buildChannelMedia.cachedEpisodes libraryID=\(library.uuid, privacy: .public) itemCount=\(cachedEpisodes.itemCount)")
                
                // Force background refresh to find additional episodes
                forceBackgroundRefresh(
                    for: cachedEpisodes,
                    library: library,
                    targetType: .episode,
                    cacheKey: episodeCacheKey
                )
                
                // Apply filters to cached episodes
                var filteredEpisodes = cachedEpisodes.items
                if !group.isEmpty {
                    filteredEpisodes = filteredEpisodes.filter { matches($0, group: group) }
                }
                
                // Apply sorting
                if let descriptor {
                    filteredEpisodes = sort(filteredEpisodes, using: descriptor)
                }
                
                // Apply limit
                if let limit, limit < filteredEpisodes.count {
                    filteredEpisodes = Array(filteredEpisodes.prefix(limit))
                }
                
                let mediaItems = filteredEpisodes.compactMap(Channel.Media.from)
                AppLoggers.channel.info("event=buildChannelMedia.cachedResult count=\(mediaItems.count)")
                return mediaItems
            }
            
            // Check disk cache for episodes
            if let diskEpisodes = await cacheStore.entry(for: episodeStoreKey) {
                mediaCache[episodeCacheKey] = diskEpisodes
                AppLoggers.channel.info("event=buildChannelMedia.diskEpisodes libraryID=\(library.uuid, privacy: .public) itemCount=\(diskEpisodes.itemCount)")
                
                // Force background refresh to find additional episodes
                forceBackgroundRefresh(
                    for: diskEpisodes,
                    library: library,
                    targetType: .episode,
                    cacheKey: episodeCacheKey
                )
                
                // Apply filters to cached episodes
                var filteredEpisodes = diskEpisodes.items
                if !group.isEmpty {
                    filteredEpisodes = filteredEpisodes.filter { matches($0, group: group) }
                }
                
                // Apply sorting
                if let descriptor {
                    filteredEpisodes = sort(filteredEpisodes, using: descriptor)
                }
                
                // Apply limit
                if let limit, limit < filteredEpisodes.count {
                    filteredEpisodes = Array(filteredEpisodes.prefix(limit))
                }
                
                let mediaItems = filteredEpisodes.compactMap(Channel.Media.from)
                AppLoggers.channel.info("event=buildChannelMedia.diskResult count=\(mediaItems.count)")
                return mediaItems
            }
            
            // No cached episodes, use two-step approach to cache episodes
            AppLoggers.channel.info("event=buildChannelMedia.noCache libraryID=\(library.uuid, privacy: .public) proceeding with full fetch")
            return try await buildChannelMediaForTVShows(
                library: library,
                using: group,
                sort: descriptor,
                limit: limit
            )
        }
        
        // For movies or episode-only filtering, use standard approach
        let mediaItems = try await fetchMedia(
            library: library,
            using: group,
            sort: descriptor,
            limit: limit
        )
        return mediaItems.compactMap(Channel.Media.from)
    }
    
    /// Force refresh the library cache for a specific library
    func forceRefreshLibraryCache(for library: PlexLibrary) async {
        let targetType = library.type == .show ? PlexMediaType.episode : library.type
        let cacheKey = makeCacheKey(for: library, mediaType: targetType)
        let storeKey = makeStoreKey(for: library, mediaType: targetType)
        
        AppLoggers.cache.info("event=libraryCache.refresh.force libraryID=\(library.uuid, privacy: .public) mediaType=\(targetType.rawValue, privacy: .public)")
        
        do {
            let refreshed = try await fetchSnapshotFromNetwork(
                library: library,
                targetType: targetType,
                effectiveLimit: nil,
                cacheKey: cacheKey,
                storeKey: storeKey,
                useMemoryCache: true,
                useDiskCache: true
            )
            AppLoggers.cache.info("event=libraryCache.refresh.forceComplete libraryID=\(library.uuid, privacy: .public) itemCount=\(refreshed.itemCount)")
        } catch {
            AppLoggers.cache.error("event=libraryCache.refresh.forceFailed libraryID=\(library.uuid, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}

private extension PlexQueryBuilder {
    func makeCacheKey(for library: PlexLibrary, mediaType: PlexMediaType) -> String {
        "\(library.uuid)_\(mediaType.rawValue)"
    }

    func makeStoreKey(for library: PlexLibrary, mediaType: PlexMediaType) -> LibraryMediaCacheStore.CacheKey {
        LibraryMediaCacheStore.CacheKey(libraryID: library.uuid, mediaType: mediaType)
    }

    func fetchSnapshotFromNetwork(
        library: PlexLibrary,
        targetType: PlexMediaType,
        effectiveLimit: Int?,
        cacheKey: String,
        storeKey: LibraryMediaCacheStore.CacheKey,
        useMemoryCache: Bool,
        useDiskCache: Bool
    ) async throws -> LibraryMediaCacheStore.Entry {
        let fetchKey: String
        if useMemoryCache {
            fetchKey = cacheKey
        } else {
            fetchKey = "\(cacheKey)#limit:\(effectiveLimit ?? -1)"
        }

        if activeFetches.contains(fetchKey) {
            AppLoggers.channel.info("event=queryBuilder.snapshot.waiting libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) reason=concurrentFetch")
            while activeFetches.contains(fetchKey) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            if useMemoryCache, let cachedEntry = mediaCache[cacheKey] {
                AppLoggers.channel.info("event=queryBuilder.snapshot.cachedAfterWait libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(cachedEntry.itemCount)")
                return cachedEntry
            }
        }

        activeFetches.insert(fetchKey)

        AppLoggers.channel.info("event=queryBuilder.snapshot.fetch libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) limit=\(effectiveLimit ?? -1)")

        let items: [PlexMediaItem]
        do {
            items = try await plexService.fetchLibraryItems(
                for: library,
                mediaType: targetType,
                limit: effectiveLimit,
                onProgress: { [weak self] count in
                    Task {
                        await self?.updateProgress(for: library.uuid, count: count)
                    }
                }
            )
        } catch {
            activeFetches.remove(fetchKey)
            AppLoggers.channel.error("event=queryBuilder.snapshot.fetchFailed libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }

        activeFetches.remove(fetchKey)

        AppLoggers.channel.info("event=queryBuilder.snapshot.fetched libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(items.count) limit=\(effectiveLimit ?? -1)")

        if useDiskCache {
            let entry = await cacheStore.updateIncrementally(newItems: items, for: storeKey)
            mediaCache[cacheKey] = entry
            lastRefreshAttempt[cacheKey] = Date()
            return entry
        }

        let entry = LibraryMediaCacheStore.Entry(
            schemaVersion: LibraryMediaCacheStore.Entry.currentSchemaVersion,
            fetchedAt: Date(),
            itemCount: items.count,
            key: storeKey,
            items: items
        )

        if useMemoryCache {
            mediaCache[cacheKey] = entry
        }

        return entry
    }

    func scheduleBackgroundRefreshIfNeeded(
        for entry: LibraryMediaCacheStore.Entry,
        library: PlexLibrary,
        targetType: PlexMediaType,
        cacheKey: String
    ) {
        guard targetType == .movie || targetType == .episode else { return }
        guard !activeFetches.contains(cacheKey) else { return }

        let refreshInterval = movieRefreshInterval
        let age = Date().timeIntervalSince(entry.fetchedAt)
        guard age >= refreshInterval else { return }

        if let lastAttempt = lastRefreshAttempt[cacheKey],
           Date().timeIntervalSince(lastAttempt) < refreshInterval {
            return
        }

        lastRefreshAttempt[cacheKey] = Date()

        AppLoggers.cache.info("event=libraryCache.refresh.schedule libraryID=\(entry.key.libraryID, privacy: .public) ageSeconds=\(Int(age)) threshold=\(Int(refreshInterval))")

        Task {
            do {
                let refreshed = try await self.fetchSnapshotFromNetwork(
                    library: library,
                    targetType: targetType,
                    effectiveLimit: nil,
                    cacheKey: cacheKey,
                    storeKey: entry.key,
                    useMemoryCache: true,
                    useDiskCache: true
                )
                AppLoggers.cache.info("event=libraryCache.refresh.complete libraryID=\(refreshed.key.libraryID, privacy: .public) count=\(refreshed.itemCount)")
            } catch {
                AppLoggers.cache.error("event=libraryCache.refresh.failed libraryID=\(entry.key.libraryID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }
    
    /// Force a background refresh regardless of time intervals
    /// Used when channel builder reaches stable state and we want to find additional content
    func forceBackgroundRefresh(
        for entry: LibraryMediaCacheStore.Entry,
        library: PlexLibrary,
        targetType: PlexMediaType,
        cacheKey: String
    ) {
        guard targetType == .movie || targetType == .episode else { return }
        guard !activeFetches.contains(cacheKey) else { return }

        // Skip if cache is less than 1 hour old (3600 seconds)
        let cacheAge = Date().timeIntervalSince(entry.fetchedAt)
        if cacheAge < 3600 {
            AppLoggers.cache.info("event=libraryCache.refresh.skip libraryID=\(entry.key.libraryID, privacy: .public) reason=cacheTooNew ageSeconds=\(Int(cacheAge))")
            return
        }

        // Skip if we've attempted a refresh recently (within 30 seconds)
        if let lastAttempt = lastRefreshAttempt[cacheKey],
           Date().timeIntervalSince(lastAttempt) < 30 {
            AppLoggers.cache.info("event=libraryCache.refresh.skip libraryID=\(entry.key.libraryID, privacy: .public) reason=recentAttempt")
            return
        }

        lastRefreshAttempt[cacheKey] = Date()

        AppLoggers.cache.info("event=libraryCache.refresh.force libraryID=\(entry.key.libraryID, privacy: .public) mediaType=\(targetType.rawValue, privacy: .public) currentCount=\(entry.itemCount)")

        Task {
            do {
                let refreshed = try await self.fetchSnapshotFromNetwork(
                    library: library,
                    targetType: targetType,
                    effectiveLimit: nil,
                    cacheKey: cacheKey,
                    storeKey: entry.key,
                    useMemoryCache: true,
                    useDiskCache: true
                )
                AppLoggers.cache.info("event=libraryCache.refresh.forceComplete libraryID=\(entry.key.libraryID, privacy: .public) itemCount=\(refreshed.itemCount) added=\(refreshed.itemCount - entry.itemCount)")
            } catch {
                AppLoggers.cache.error("event=libraryCache.refresh.forceFailed libraryID=\(entry.key.libraryID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func applyLimitIfNeeded(_ items: [PlexMediaItem], limit: Int?) -> [PlexMediaItem] {
        guard let limit, limit > 0 else { return items }
        if items.count <= limit {
            return items
        }
        return Array(items.prefix(limit))
    }
}

// MARK: - TV Show Filtering

private extension PlexQueryBuilder {
    /// Checks if the filter group contains any show-level fields (like show title)
    func hasShowLevelFilters(_ group: FilterGroup) -> Bool {
        // Check if any rules target show-level fields
        for rule in group.rules {
            if isShowLevelField(rule.field) {
                return true
            }
        }
        
        // Check nested groups recursively
        for nestedGroup in group.groups {
            if hasShowLevelFilters(nestedGroup) {
                return true
            }
        }
        
        return false
    }
    
    /// Determines if a filter field applies to shows rather than episodes
    func isShowLevelField(_ field: FilterField) -> Bool {
        // For TV libraries, "title" means the show title, not episode title
        // Episode title would be accessed via a different field
        switch field {
        case .title:  // When filtering TV Shows library, this is the show title
            return true
        case .network, .studio, .contentRating, .year, .country:
            return true
        // All other fields apply to episodes
        default:
            return false
        }
    }
    
    /// Two-step filtering for TV shows:
    /// 1. Filter shows by show-level criteria
    /// 2. Expand to episodes from matching shows
    /// 3. Apply episode-level filters if any
    func buildChannelMediaForTVShows(
        library: PlexLibrary,
        using group: FilterGroup,
        sort descriptor: SortDescriptor?,
        limit: Int? = nil
    ) async throws -> [Channel.Media] {
        // Step 1: Separate show-level and episode-level filters
        let showFilters = extractShowLevelFilters(group)
        let episodeFilters = extractEpisodeLevelFilters(group)
        
        AppLoggers.channel.info("event=tvFilter.start showFilterEmpty=\(showFilters.isEmpty) episodeFilterEmpty=\(episodeFilters.isEmpty)")
        
        // Step 2: Get all shows from cache (already fetched by mediaSnapshot)
        let allShows = try await mediaSnapshot(for: library, limit: nil)
        
        AppLoggers.channel.info("event=tvFilter.fetchedShows count=\(allShows.count)")
        
        // Debug: Log some sample shows to see what we're getting
        let sampleShows = allShows.prefix(5)
        for (index, show) in sampleShows.enumerated() {
            AppLoggers.channel.info("event=tvFilter.debug sampleShow[\(index)] title=\(show.title ?? "unknown") ratingKey=\(show.ratingKey)")
        }
        
        // Debug: Log the show filters being applied
        AppLoggers.channel.info("event=tvFilter.debug showFilters rules=\(showFilters.rules.count) groups=\(showFilters.groups.count)")
        for (index, rule) in showFilters.rules.enumerated() {
            AppLoggers.channel.info("event=tvFilter.debug showRule[\(index)] field=\(rule.field.displayName) op=\(rule.op.rawValue) value=\(rule.value.debugDescription)")
        }
        
        let matchingShows = showFilters.isEmpty ? allShows : allShows.filter { show in
            let matches = matches(show, group: showFilters)
            AppLoggers.channel.info("event=tvFilter.debug showMatch title=\(show.title ?? "unknown") matches=\(matches)")
            return matches
        }
        
        AppLoggers.channel.info("event=tvFilter.matchedShows count=\(matchingShows.count) titles=\(matchingShows.prefix(10).map { $0.title ?? "unknown" }.joined(separator: ", "))")
        
        // Debug: show the actual shows we're about to process
        for (index, show) in matchingShows.enumerated() {
            AppLoggers.channel.info("event=tvFilter.debug matchedShow index=\(index) title=\(show.title ?? "unknown") key=\(show.ratingKey)")
        }
        
        // Step 3: Sort shows by newest first to prioritize recent content
        let sortedShows = matchingShows.sorted { show1, show2 in
            let date1 = show1.addedAt ?? .distantPast
            let date2 = show2.addedAt ?? .distantPast
            return date1 > date2  // Newest first
        }
        
        AppLoggers.channel.info("event=tvFilter.sortedShows count=\(sortedShows.count) newestFirst=true")
        
        // Step 4: Fetch episodes directly from each matching show
        // We need to fetch episodes for each show individually since the library cache
        // doesn't contain all episodes from all shows
        var allEpisodes: [PlexMediaItem] = []
        var savedEpisodesCount = 0
        
        for (index, show) in sortedShows.enumerated() {
            do {
                AppLoggers.channel.info("event=tvFilter.debug processingShow index=\(index) showTitle=\(show.title ?? "unknown") showKey=\(show.ratingKey) showKeyField=\(show.key)")
                AppLoggers.channel.info("event=tvFilter.debug loopStart index=\(index) showTitle=\(show.title ?? "unknown") showKey=\(show.ratingKey) showKeyField=\(show.key)")
                
                // CRITICAL: Verify we're processing the correct show
                // The show title should match what we expect from the matchedShows array
                let expectedTitle = show.title ?? "unknown"
                AppLoggers.channel.info("event=tvFilter.debug verifyingShow expectedTitle=\(expectedTitle) actualTitle=\(show.title ?? "unknown")")
                
                // Fetch episodes directly from this specific show
                // Use the show's ratingKey (numeric ID) to fetch episodes
                // show.ratingKey is like "1856101"
                AppLoggers.channel.info("event=tvFilter.debug fetchingEpisodes show=\(show.title ?? "unknown") showKey=\(show.key) ratingKey=\(show.ratingKey)")
                
                // Fetch episodes directly using the show's ratingKey
                guard let currentSession = await plexService.session else {
                    throw PlexService.ServiceError.noActiveSession
                }
                let token = currentSession.server.accessToken
                let showEpisodes = try await plexService.fetchShowEpisodes(
                    showRatingKey: show.ratingKey,
                    baseURL: currentSession.server.baseURL,
                    token: token
                )
                
                AppLoggers.channel.info("event=tvFilter.debug showEpisodes show=\(show.title ?? "unknown") count=\(showEpisodes.count) showKey=\(show.ratingKey)")
                
                // Log sample episodes from this show
                let sampleEpisodes = showEpisodes.prefix(3)
                for (idx, episode) in sampleEpisodes.enumerated() {
                    AppLoggers.channel.info("event=tvFilter.debug showEpisode[\(idx)] title=\(episode.title ?? "unknown") grandparentKey=\(episode.grandparentRatingKey ?? "nil") grandparentTitle=\(episode.grandparentTitle ?? "nil")")
                }
                
                allEpisodes.append(contentsOf: showEpisodes)
                
                // Incremental save: Save episodes after each show to avoid losing progress
                if !showEpisodes.isEmpty {
                    let episodeCacheKey = LibraryMediaCacheStore.CacheKey(
                        libraryID: library.uuid,
                        mediaType: .episode
                    )
                    // Use regular store to replace cache with cumulative episodes
                    await cacheStore.store(items: allEpisodes, for: episodeCacheKey)
                    savedEpisodesCount = allEpisodes.count
                    AppLoggers.cache.info("event=libraryCache.store libraryID=\(library.uuid, privacy: .public) mediaType=episode count=\(savedEpisodesCount) show=\(show.title ?? "unknown", privacy: .public)")
                }
            } catch {
                AppLoggers.channel.error("event=tvFilter.debug showEpisodesError show=\(show.title ?? "unknown") error=\(error)")
            }
        }
        
        // Final summary: Episodes were saved incrementally during the loop
        AppLoggers.cache.info("event=libraryCache.store.complete libraryID=\(library.uuid, privacy: .public) mediaType=episode totalCount=\(allEpisodes.count) showsProcessed=\(sortedShows.count)")
        
        AppLoggers.channel.info("event=tvFilter.fetchedEpisodes count=\(allEpisodes.count)")
        
        // Debug: Check what we actually got
        if let first = allEpisodes.first {
            let hasGrandparent = first.grandparentRatingKey != nil
            let gpKey = first.grandparentRatingKey ?? "nil"
            let gpTitle = first.grandparentTitle ?? "nil"
            AppLoggers.channel.info("event=tvFilter.debug firstItem hasGrandparent=\(hasGrandparent) grandparentKey=\(gpKey) grandparentTitle=\(gpTitle) ratingKey=\(first.ratingKey)")
        }
        
        // Debug: Log some sample episodes to see what we're getting
        let sampleEpisodes = allEpisodes.prefix(3)
        for (index, episode) in sampleEpisodes.enumerated() {
            AppLoggers.channel.info("event=tvFilter.debug sampleEpisode[\(index)] title=\(episode.title ?? "unknown") grandparentTitle=\(episode.grandparentTitle ?? "unknown")")
        }
        
        // Step 4: All episodes are already from matching shows, no need to filter
        var episodesFromMatchingShows = allEpisodes
        AppLoggers.channel.info("event=tvFilter.episodesFromShows count=\(episodesFromMatchingShows.count)")
        
        // Step 5: Apply episode-level filters if any
        if !episodeFilters.isEmpty {
            episodesFromMatchingShows = episodesFromMatchingShows.filter { episode in
                matches(episode, group: episodeFilters)
            }
            AppLoggers.channel.info("event=tvFilter.afterEpisodeFilters count=\(episodesFromMatchingShows.count)")
        }
        
        // Step 6: Apply sorting
        if let descriptor {
            episodesFromMatchingShows = sort(episodesFromMatchingShows, using: descriptor)
        }
        
        // Step 7: Apply limit
        if let limit, limit < episodesFromMatchingShows.count {
            episodesFromMatchingShows = Array(episodesFromMatchingShows.prefix(limit))
        }
        
        let mediaItems = episodesFromMatchingShows.compactMap(Channel.Media.from)
        AppLoggers.channel.info("event=tvFilter.final count=\(mediaItems.count)")
        
        return mediaItems
    }
    
    /// Extracts only the show-level filters from a filter group
    func extractShowLevelFilters(_ group: FilterGroup) -> FilterGroup {
        var showRules: [FilterRule] = []
        var showGroups: [FilterGroup] = []
        
        AppLoggers.channel.info("event=tvFilter.debug extractShowLevelFilters input rules=\(group.rules.count) groups=\(group.groups.count)")
        
        for rule in group.rules {
            let isShowLevel = isShowLevelField(rule.field)
            AppLoggers.channel.info("event=tvFilter.debug extractShowLevelFilters rule field=\(rule.field.displayName) isShowLevel=\(isShowLevel)")
            if isShowLevel {
                showRules.append(rule)
            }
        }
        
        for nestedGroup in group.groups {
            let extracted = extractShowLevelFilters(nestedGroup)
            if !extracted.isEmpty {
                showGroups.append(extracted)
            }
        }
        
        let result = FilterGroup(mode: group.mode, rules: showRules, groups: showGroups)
        AppLoggers.channel.info("event=tvFilter.debug extractShowLevelFilters result rules=\(result.rules.count) groups=\(result.groups.count) isEmpty=\(result.isEmpty)")
        
        return result
    }
    
    /// Extracts only the episode-level filters from a filter group
    func extractEpisodeLevelFilters(_ group: FilterGroup) -> FilterGroup {
        var episodeRules: [FilterRule] = []
        var episodeGroups: [FilterGroup] = []
        
        for rule in group.rules {
            if !isShowLevelField(rule.field) {
                episodeRules.append(rule)
            }
        }
        
        for nestedGroup in group.groups {
            let extracted = extractEpisodeLevelFilters(nestedGroup)
            if !extracted.isEmpty {
                episodeGroups.append(extracted)
            }
        }
        
        return FilterGroup(mode: group.mode, rules: episodeRules, groups: episodeGroups)
    }
}

// MARK: - Filtering

private extension PlexQueryBuilder {
    func matches(_ item: PlexMediaItem, group: FilterGroup) -> Bool {
        guard !group.rules.isEmpty || !group.groups.isEmpty else { return true }

        let ruleMatches = group.rules.map { matches(item, rule: $0) }
        let groupMatches = group.groups.map { matches(item, group: $0) }
        let allResults = ruleMatches + groupMatches

        switch group.mode {
        case .all:
            return allResults.allSatisfy { $0 }
        case .any:
            return allResults.contains(true)
        }
    }

    func matches(_ item: PlexMediaItem, rule: FilterRule) -> Bool {
        switch rule.field.valueKind {
        case .text:
            guard let search = extractString(from: rule.value) else { return false }
            let candidate = FilterFieldResolver.stringValue(rule.field, from: item)
            return compareText(candidate: candidate, search: search, operator: rule.op)

        case .enumSingle, .enumMulti:
            let candidates = FilterFieldResolver.stringValues(rule.field, from: item)
            let values = extractValues(from: rule.value)
            return compareEnumerations(candidates: candidates, values: values, operator: rule.op)

        case .number:
            guard let number = extractNumber(from: rule.value) else { return false }
            let candidate = FilterFieldResolver.numberValue(rule.field, from: item)
            return compareNumbers(candidate: candidate, value: number, operator: rule.op)

        case .date:
            let candidate = FilterFieldResolver.dateValue(rule.field, from: item)
            return compareDates(candidate: candidate, value: rule.value, operator: rule.op)

        case .boolean:
            guard let expected = extractBoolean(from: rule.value) else { return false }
            let candidate = FilterFieldResolver.boolValue(rule.field, from: item)
            return compareBooleans(candidate: candidate, value: expected, operator: rule.op)
        }
    }
}

// MARK: - Comparisons

private extension PlexQueryBuilder {
    func compareText(candidate: String?, search: String, operator op: FilterOperator) -> Bool {
        guard let candidate else {
            return op == .notEquals
        }
        switch op {
        case .contains:
            return candidate.localizedCaseInsensitiveContains(search)
        case .notContains:
            return !candidate.localizedCaseInsensitiveContains(search)
        case .equals:
            return candidate.localizedCaseInsensitiveCompare(search) == .orderedSame
        case .notEquals:
            return candidate.localizedCaseInsensitiveCompare(search) != .orderedSame
        case .beginsWith:
            return candidate.lowercased().hasPrefix(search.lowercased())
        case .endsWith:
            return candidate.lowercased().hasSuffix(search.lowercased())
        default:
            return false
        }
    }

    func compareEnumerations(
        candidates: [String],
        values: [String],
        operator op: FilterOperator
    ) -> Bool {
        guard !values.isEmpty else { return false }

        let normalizedCandidates = Set(candidates.map { $0.lowercased() })
        let normalizedValues = Set(values.map { $0.lowercased() })

        switch op {
        case .equals:
            return !normalizedCandidates.isDisjoint(with: normalizedValues)
        case .notEquals:
            return normalizedCandidates.isDisjoint(with: normalizedValues)
        default:
            // Unsupported comparison for enums.
            return false
        }
    }

    func compareNumbers(
        candidate: Double?,
        value: Double,
        operator op: FilterOperator
    ) -> Bool {
        guard let candidate else { return false }
        switch op {
        case .lessThan:
            return candidate < value
        case .lessThanOrEqual:
            return candidate <= value
        case .greaterThan:
            return candidate > value
        case .greaterThanOrEqual:
            return candidate >= value
        case .equals:
            return abs(candidate - value) < 0.0001
        case .notEquals:
            return abs(candidate - value) >= 0.0001
        default:
            return false
        }
    }

    func compareBooleans(
        candidate: Bool?,
        value: Bool,
        operator op: FilterOperator
    ) -> Bool {
        guard let candidate else { return false }
        switch op {
        case .equals:
            return candidate == value
        case .notEquals:
            return candidate != value
        default:
            return false
        }
    }

    func compareDates(
        candidate: Date?,
        value: FilterValue,
        operator op: FilterOperator
    ) -> Bool {
        guard let candidate else { return false }
        let calendar = Calendar.current

        switch op {
        case .before:
            guard let range = resolveDateValue(from: value, calendar: calendar) else { return false }
            return candidate < range.lowerBound
        case .after:
            guard let range = resolveDateValue(from: value, calendar: calendar) else { return false }
            return candidate > range.upperBound
        case .on:
            guard let range = resolveDateValue(from: value, calendar: calendar) else { return false }
            return range.contains(candidate)
        case .inTheLast:
            guard let threshold = resolveRelativeDateThreshold(from: value) else { return false }
            return candidate >= threshold
        case .notInTheLast:
            guard let threshold = resolveRelativeDateThreshold(from: value) else { return false }
            return candidate < threshold
        default:
            return false
        }
    }

    func resolveDateValue(
        from value: FilterValue,
        calendar: Calendar
    ) -> ClosedRange<Date>? {
        switch value {
        case .date(let date):
            let start = calendar.startOfDay(for: date)
            guard let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) else {
                return start...start
            }
            return start...end
        case .relativeDate(let preset):
            return preset.resolveRange(calendar: calendar, now: Date())
        case .relativeDateSpec(let spec):
            let threshold = spec.dateAgo
            return threshold...Date()
        default:
            return nil
        }
    }

    func resolveRelativeDateThreshold(from value: FilterValue) -> Date? {
        switch value {
        case .relativeDateSpec(let spec):
            return spec.dateAgo
        case .relativeDate(let preset):
            // Convert preset to threshold for "in the last" operations
            let calendar = Calendar.current
            let now = Date()
            switch preset {
            case .today:
                return calendar.startOfDay(for: now)
            case .last7Days:
                return calendar.date(byAdding: .day, value: -7, to: now)
            case .last30Days:
                return calendar.date(byAdding: .day, value: -30, to: now)
            case .last90Days:
                return calendar.date(byAdding: .day, value: -90, to: now)
            case .last365Days:
                return calendar.date(byAdding: .day, value: -365, to: now)
            case .custom(let days):
                return calendar.date(byAdding: .day, value: -days, to: now)
            }
        default:
            return nil
        }
    }
}

// MARK: - Sorting

private extension PlexQueryBuilder {
    func sort(_ items: [PlexMediaItem], using descriptor: SortDescriptor) -> [PlexMediaItem] {
        guard descriptor.key != .random else {
            return items.shuffled()
        }

        return items.sorted { lhs, rhs in
            let comparison = compare(lhs: lhs, rhs: rhs, key: descriptor.key)
            if descriptor.order == .ascending {
                return comparison
            } else {
                return !comparison
            }
        }
    }

    func compare(lhs: PlexMediaItem, rhs: PlexMediaItem, key: SortDescriptor.SortKey) -> Bool {
        switch key {
        case .title:
            return (lhs.title ?? "") < (rhs.title ?? "")
        case .year:
            return (lhs.year ?? 0) < (rhs.year ?? 0)
        case .originallyAvailableAt, .episodeAirDate:
            return (lhs.originallyReleasedAt ?? .distantPast) < (rhs.originallyReleasedAt ?? .distantPast)
        case .rating, .criticRating:
            return (lhs.rating ?? 0) < (rhs.rating ?? 0)
        case .audienceRating:
            return (lhs.userRating ?? 0) < (rhs.userRating ?? 0)
        case .contentRating:
            return (lhs.contentRating ?? "") < (rhs.contentRating ?? "")
        case .addedAt:
            return (lhs.addedAt ?? .distantPast) < (rhs.addedAt ?? .distantPast)
        case .lastViewedAt:
            return (lhs.lastViewedAt ?? .distantPast) < (rhs.lastViewedAt ?? .distantPast)
        case .viewCount:
            return (lhs.viewCount ?? 0) < (rhs.viewCount ?? 0)
        case .unviewed:
            let lhsUnviewed = (lhs.viewCount ?? 0) == 0
            let rhsUnviewed = (rhs.viewCount ?? 0) == 0
            return lhsUnviewed && !rhsUnviewed
        case .showTitle:
            return (lhs.grandparentTitle ?? lhs.parentTitle ?? "") < (rhs.grandparentTitle ?? rhs.parentTitle ?? "")
        case .random:
            return true
        }
    }
}

// MARK: - Value Extraction Helpers

private extension PlexQueryBuilder {
    func extractString(from value: FilterValue) -> String? {
        switch value {
        case .text(let string):
            return string
        case .enumCase(let string):
            return string
        case .enumSet(let values):
            return values.first
        default:
            return nil
        }
    }

    func extractValues(from value: FilterValue) -> [String] {
        switch value {
        case .text(let string):
            return [string]
        case .enumCase(let string):
            return [string]
        case .enumSet(let values):
            return values
        default:
            return []
        }
    }

    func extractNumber(from value: FilterValue) -> Double? {
        switch value {
        case .number(let double):
            return double
        case .text(let string):
            return Double(string)
        default:
            return nil
        }
    }

    func extractBoolean(from value: FilterValue) -> Bool? {
        switch value {
        case .boolean(let bool):
            return bool
        case .text(let string):
            let lowercased = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "1"].contains(lowercased) {
                return true
            }
            if ["false", "no", "0"].contains(lowercased) {
                return false
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Relative Date Resolution

extension RelativeDatePreset {
    func resolveRange(calendar: Calendar = .current, now: Date = Date()) -> ClosedRange<Date> {
        switch self {
        case .today:
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? now
            return start...end
        case .last7Days:
            return resolveRange(days: 7, calendar: calendar, now: now)
        case .last30Days:
            return resolveRange(days: 30, calendar: calendar, now: now)
        case .last90Days:
            return resolveRange(days: 90, calendar: calendar, now: now)
        case .last365Days:
            return resolveRange(days: 365, calendar: calendar, now: now)
        case .custom(let days):
            return resolveRange(days: days, calendar: calendar, now: now)
        }
    }

    private func resolveRange(days: Int, calendar: Calendar, now: Date) -> ClosedRange<Date> {
        let end = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: now)) ?? now
        let startDate = calendar.date(byAdding: .day, value: -max(days - 1, 0), to: calendar.startOfDay(for: now)) ?? now
        return startDate...end
    }
}
