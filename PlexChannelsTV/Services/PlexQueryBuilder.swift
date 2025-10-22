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

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func invalidateCache(for libraryID: String) {
        mediaCache.removeValue(forKey: libraryID)
    }

    func mediaSnapshot(for library: PlexLibrary, limit: Int? = nil) async throws -> [PlexMediaItem] {
        let cacheKey = library.uuid

        if limit == nil, let cached = mediaCache[cacheKey] {
            return cached
        }

        let items = try await plexService.fetchLibraryItems(for: library, limit: limit)

        if limit == nil {
            mediaCache[cacheKey] = items
        } else if mediaCache[cacheKey] == nil {
            mediaCache[cacheKey] = items
        }

        return items
    }

    func count(
        library: PlexLibrary,
        using group: FilterGroup
    ) async throws -> Int {
        let items = try await mediaSnapshot(for: library, limit: nil)
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
        let mediaItems = try await fetchMedia(
            library: library,
            using: group,
            sort: descriptor,
            limit: limit
        )
        return mediaItems.compactMap(Channel.Media.from)
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
