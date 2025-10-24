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
    private var mediaCache: [String: [PlexMediaItem]] = [:]
    private var progressCallback: ((String, Int) -> Void)?

    init(plexService: PlexService) {
        self.plexService = plexService
    }
    
    func setProgressCallback(_ callback: @escaping (String, Int) -> Void) {
        progressCallback = callback
    }

    private func preferredMediaType(for library: PlexLibrary) -> PlexMediaType {
        switch library.type {
        case .show:
            return .episode
        default:
            return library.type
        }
    }

    func invalidateCache(for libraryID: String) {
        mediaCache.removeValue(forKey: libraryID)
    }
    
    func invalidateAllCache() {
        mediaCache.removeAll()
    }
    
    func updateProgress(for libraryID: String, count: Int) {
        progressCallback?(libraryID, count)
    }

    func mediaSnapshot(for library: PlexLibrary, limit: Int? = nil) async throws -> [PlexMediaItem] {
        let cacheKey = library.uuid
        let targetType = preferredMediaType(for: library)

        // Only use cache if we're not requesting the full library
        // This ensures that when we want the full library, we always fetch fresh
        if limit != nil, let cached = mediaCache[cacheKey] {
            AppLoggers.channel.info("event=queryBuilder.snapshot.cache libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(cached.count) limit=\(limit ?? -1)")
            return cached
        }

        // Apply different default limits based on library type
        // For movies: allow up to 10,000 items (no practical limit)
        // For TV episodes: use 800 to avoid overwhelming the system
        let effectiveLimit: Int? = {
            if let customLimit = limit {
                return customLimit
            }
            // Don't apply a limit by default - fetch everything
            return nil
        }()

        AppLoggers.channel.info("event=queryBuilder.snapshot.fetch libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) limit=\(effectiveLimit ?? -1)")

        let items = try await plexService.fetchLibraryItems(
            for: library,
            mediaType: targetType,
            limit: effectiveLimit,
            onProgress: { [weak self] count in
                Task {
                    await self?.updateProgress(for: library.uuid, count: count)
                }
            }
        )

        AppLoggers.channel.info("event=queryBuilder.snapshot.fetched libraryType=\(library.type.rawValue) libraryID=\(library.uuid, privacy: .public) itemCount=\(items.count) limit=\(effectiveLimit ?? -1)")

        // Only cache if we're not fetching the full library
        // This prevents the cache from being populated with limited results
        if limit != nil {
            mediaCache[cacheKey] = items
        }

        return items
    }

    func count(
        library: PlexLibrary,
        using group: FilterGroup
    ) async throws -> Int {
        // For TV libraries with show-level filters, use two-step process
        if library.type == .show && hasShowLevelFilters(group) {
            let media = try await buildChannelMediaForTVShows(
                library: library,
                using: group,
                sort: nil,
                limit: nil
            )
            return media.count
        }
        
        // For movies or episode-only filtering, use standard approach
        // Clear cache to ensure we get the full library for movies
        if library.type == .movie {
            invalidateCache(for: library.uuid)
            AppLoggers.channel.info("event=queryBuilder.count.clearCache libraryType=movie libraryID=\(library.uuid, privacy: .public)")
        }
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
        // Clear cache to ensure we get the full library for movies
        if library.type == .movie {
            invalidateCache(for: library.uuid)
        }
        var items = try await mediaSnapshot(for: library, limit: nil)
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
        // For TV libraries, check if we're filtering by show-level fields
        // If so, we need to find shows first, then expand to their episodes
        if library.type == .show && hasShowLevelFilters(group) {
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
        
        // Step 2: Fetch all shows and filter by show-level criteria
        let allShows = try await plexService.fetchLibraryItems(
            for: library,
            mediaType: .show,
            limit: nil
        )
        
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
        
        // Step 3: Fetch episodes directly from each matching show
        // We need to fetch episodes for each show individually since the library cache
        // doesn't contain all episodes from all shows
        var allEpisodes: [PlexMediaItem] = []
        
        for (index, show) in matchingShows.enumerated() {
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
            } catch {
                AppLoggers.channel.error("event=tvFilter.debug showEpisodesError show=\(show.title ?? "unknown") error=\(error)")
            }
        }
        
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
