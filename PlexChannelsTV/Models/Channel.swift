//
//  Channel.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import Foundation
import PlexKit

struct Channel: Identifiable, Codable, Hashable {
    struct SourceLibrary: Codable, Hashable {
        var id: String?
        var key: String
        var title: String?
        var type: PlexMediaType

        init(
            id: String? = nil,
            key: String,
            title: String? = nil,
            type: PlexMediaType
        ) {
            self.id = id
            self.key = key
            self.title = title
            self.type = type
        }
    }

    struct Options: Codable, Hashable {
        var shuffle: Bool

        init(shuffle: Bool = false) {
            self.shuffle = shuffle
        }
    }

    enum Provenance: Hashable {
        case library(key: String)
        case seed(identifier: String)
        case filters(ChannelDraft)
    }

    struct Media: Identifiable, Codable, Hashable {
        let id: String
        let title: String
        /// Duration in seconds.
        let duration: TimeInterval
        let metadataKey: String?
        let partKey: String?
        let partID: Int?
        let metadata: Metadata?
        let artwork: Artwork

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case duration
            case metadataKey
            case partKey
            case partID
            case metadata
            case artwork
        }

        struct Metadata: Codable, Hashable {
            let title: String?
            let year: Int?
            let genres: [String]
            let addedAt: Date?
            let type: PlexMediaType?
            let guid: String?
            let originallyAvailableAt: Date?
            let lastViewedAt: Date?
            let viewCount: Int?
            let contentRating: String?
            let grandparentTitle: String?
            let rating: Double?
            let audienceRating: Double?
        }

        struct Artwork: Codable, Hashable {
            let thumb: String?
            let art: String?
            let parentThumb: String?
            let grandparentThumb: String?
            let grandparentArt: String?
            let grandparentTheme: String?
            let theme: String?

            init(
                thumb: String? = nil,
                art: String? = nil,
                parentThumb: String? = nil,
                grandparentThumb: String? = nil,
                grandparentArt: String? = nil,
                grandparentTheme: String? = nil,
                theme: String? = nil
            ) {
                self.thumb = thumb
                self.art = art
                self.parentThumb = parentThumb
                self.grandparentThumb = grandparentThumb
                self.grandparentArt = grandparentArt
                self.grandparentTheme = grandparentTheme
                self.theme = theme
            }

            var isEmpty: Bool {
                thumb == nil &&
                art == nil &&
                parentThumb == nil &&
                grandparentThumb == nil &&
                grandparentArt == nil &&
                grandparentTheme == nil &&
                theme == nil
            }
        }

        init(
            id: String,
            title: String,
            duration: TimeInterval,
            metadataKey: String? = nil,
            partKey: String? = nil,
            partID: Int? = nil,
            metadata: Metadata? = nil,
            artwork: Artwork = Artwork()
        ) {
            self.id = id
            self.title = title
            self.duration = duration
            self.metadataKey = metadataKey
            self.partKey = partKey
            self.partID = partID
            self.metadata = metadata
            self.artwork = artwork
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            duration = try container.decode(TimeInterval.self, forKey: .duration)
            metadataKey = try container.decodeIfPresent(String.self, forKey: .metadataKey)
            partKey = try container.decodeIfPresent(String.self, forKey: .partKey)
            partID = try container.decodeIfPresent(Int.self, forKey: .partID)
            metadata = try container.decodeIfPresent(Metadata.self, forKey: .metadata)
            artwork = try container.decodeIfPresent(Artwork.self, forKey: .artwork) ?? Artwork()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(duration, forKey: .duration)
            try container.encodeIfPresent(metadataKey, forKey: .metadataKey)
            try container.encodeIfPresent(partKey, forKey: .partKey)
            try container.encodeIfPresent(partID, forKey: .partID)
            try container.encodeIfPresent(metadata, forKey: .metadata)
            if !artwork.isEmpty {
                try container.encode(artwork, forKey: .artwork)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case libraryKey
        case libraryType
        case createdAt
        case scheduleAnchor
        case items
        case sourceLibraries
        case options
        case provenance
    }

    let id: UUID
    let name: String
    let libraryKey: String
    let libraryType: PlexMediaType
    let createdAt: Date
    /// Reference point for the start of the playlist loop.
    let scheduleAnchor: Date
    let items: [Media]
    let sourceLibraries: [SourceLibrary]
    let options: Options
    let provenance: Provenance

    init(
        id: UUID = UUID(),
        name: String,
        libraryKey: String,
        libraryType: PlexMediaType,
        createdAt: Date = Date(),
        scheduleAnchor: Date = Date(),
        items: [Media],
        sourceLibraries: [SourceLibrary]? = nil,
        options: Options = Options(),
        provenance: Provenance? = nil
    ) {
        self.id = id
        self.name = name
        self.libraryKey = libraryKey
        self.libraryType = libraryType
        self.createdAt = createdAt
        self.scheduleAnchor = scheduleAnchor
        self.items = items
        if let sourceLibraries, !sourceLibraries.isEmpty {
            self.sourceLibraries = sourceLibraries
        } else {
            self.sourceLibraries = [
                SourceLibrary(
                    id: nil,
                    key: libraryKey,
                    title: nil,
                    type: libraryType
                )
            ]
        }
        self.options = options
        if let provenance {
            self.provenance = provenance
        } else {
            self.provenance = .library(key: libraryKey)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        libraryKey = try container.decode(String.self, forKey: .libraryKey)
        libraryType = try container.decode(PlexMediaType.self, forKey: .libraryType)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        scheduleAnchor = try container.decode(Date.self, forKey: .scheduleAnchor)
        items = try container.decode([Media].self, forKey: .items)
        if let decodedSources = try container.decodeIfPresent([SourceLibrary].self, forKey: .sourceLibraries),
           !decodedSources.isEmpty {
            sourceLibraries = decodedSources
        } else {
            sourceLibraries = [
                SourceLibrary(
                    id: nil,
                    key: libraryKey,
                    title: nil,
                    type: libraryType
                )
            ]
        }
        options = try container.decodeIfPresent(Options.self, forKey: .options) ?? Options()
        provenance = try container.decodeIfPresent(Provenance.self, forKey: .provenance) ?? .library(key: libraryKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(libraryKey, forKey: .libraryKey)
        try container.encode(libraryType, forKey: .libraryType)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(scheduleAnchor, forKey: .scheduleAnchor)
        try container.encode(items, forKey: .items)
        if !sourceLibraries.isEmpty {
            try container.encode(sourceLibraries, forKey: .sourceLibraries)
        }
        if options.shuffle {
            try container.encode(options, forKey: .options)
        }
        try container.encode(provenance, forKey: .provenance)
    }

    var primaryLibrary: SourceLibrary? {
        sourceLibraries.first
    }

    var primaryLibraryType: PlexMediaType {
        primaryLibrary?.type ?? libraryType
    }

    var totalDuration: TimeInterval {
        items.reduce(0) { partialResult, media in
            partialResult + max(0, media.duration)
        }
    }

    /// Returns the item index, media, and playback offset for a given point in time.
    func playbackPosition(at date: Date = .init()) -> (index: Int, media: Media, offset: TimeInterval)? {
        guard !items.isEmpty else { return nil }

        let loopDuration = totalDuration
        guard loopDuration > 0 else { return nil }

        let elapsed = max(0, date.timeIntervalSince(scheduleAnchor))
        var position = elapsed.truncatingRemainder(dividingBy: loopDuration)

        for (index, media) in items.enumerated() {
            let duration = max(0, media.duration)
            if position < duration {
                return (index, media, position)
            }
            position -= duration
        }

        if let lastIndex = items.indices.last {
            return (lastIndex, items[lastIndex], 0)
        }
        return nil
    }

    /// Returns the media item and playback offset for a given point in time.
    func playbackState(at date: Date = .init()) -> (media: Media, offset: TimeInterval)? {
        guard let position = playbackPosition(at: date) else { return nil }
        return (position.media, position.offset)
    }

    func nowPlaying(at date: Date = .init()) -> Media? {
        playbackPosition(at: date)?.media
    }

    func nowPlayingTitle(at date: Date = .init()) -> String? {
        nowPlaying(at: date)?.title
    }

    func timeRemaining(at date: Date = .init()) -> TimeInterval? {
        guard let position = playbackPosition(at: date) else { return nil }
        return max(0, position.media.duration - position.offset)
    }

    func nextUp(after date: Date = .init()) -> Media? {
        guard let position = playbackPosition(at: date) else { return nil }
        guard !items.isEmpty else { return nil }
        let nextIndex = (position.index + 1) % items.count
        return items[nextIndex]
    }
}

extension Channel.Media {
    static func from(_ item: PlexMediaItem) -> Channel.Media? {
        guard let duration = item.duration, duration > 0 else { return nil }
        let firstPart = item.media.first?.parts.first
        return Channel.Media(
            id: item.ratingKey,
            title: item.title ?? "Untitled",
            duration: TimeInterval(duration) / 1000.0,
            metadataKey: item.key,
            partKey: firstPart?.key,
            partID: firstPart?.id,
            metadata: Channel.Media.Metadata(
                title: item.title,
                year: item.year,
                genres: item.genres.map { $0.tag },
                addedAt: item.addedAt,
                type: item.type,
                guid: item.guid,
                originallyAvailableAt: item.originallyReleasedAt,
                lastViewedAt: item.lastViewedAt,
                viewCount: item.viewCount,
                contentRating: item.contentRating,
                grandparentTitle: item.grandparentTitle,
                rating: item.rating,
                audienceRating: item.userRating
            ),
            artwork: Channel.Media.Artwork(
                thumb: item.thumb,
                art: item.art,
                parentThumb: item.parentThumb,
                grandparentThumb: item.grandparentThumb,
                grandparentArt: item.grandparentArt,
                grandparentTheme: item.grandparentTheme,
                theme: item.theme
            )
        )
    }

    var backgroundArtworkCandidates: [String] {
        [
            artwork.art,
            artwork.grandparentArt,
            artwork.thumb,
            artwork.parentThumb,
            artwork.grandparentThumb
        ].compactMap { $0 }
    }

    var posterArtworkCandidates: [String] {
        [
            artwork.thumb,
            artwork.parentThumb,
            artwork.grandparentThumb,
            artwork.art,
            artwork.grandparentArt
        ].compactMap { $0 }
    }

    var logoArtworkCandidates: [String] {
        // For movies, Plex stores clearLogos at /library/metadata/{ratingKey}/clearLogo
        // Try this first, then fall back to theme fields (for TV shows)
        [
            "/library/metadata/\(id)/clearLogo",
            artwork.grandparentTheme,
            artwork.theme
        ].compactMap { $0 }
    }
}

extension Array where Element == Channel.Media {
    func sorted(using descriptor: SortDescriptor) -> [Channel.Media] {
        guard descriptor.key != .random else { return self }
        return sorted { lhs, rhs in
            compare(lhs: lhs, rhs: rhs, key: descriptor.key, order: descriptor.order)
        }
    }

    private func compare(
        lhs: Channel.Media,
        rhs: Channel.Media,
        key: SortDescriptor.SortKey,
        order: SortDescriptor.Order
    ) -> Bool {
        let ascending = order == .ascending

        switch key {
        case .title:
            let left = lhs.metadata?.title ?? lhs.title
            let right = rhs.metadata?.title ?? rhs.title
            return ascending ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending : left.localizedCaseInsensitiveCompare(right) == .orderedDescending

        case .showTitle:
            let left = lhs.metadata?.grandparentTitle ?? lhs.metadata?.title ?? lhs.title
            let right = rhs.metadata?.grandparentTitle ?? rhs.metadata?.title ?? rhs.title
            return ascending ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending : left.localizedCaseInsensitiveCompare(right) == .orderedDescending

        case .year:
            let left = lhs.metadata?.year ?? 0
            let right = rhs.metadata?.year ?? 0
            return ascending ? left < right : left > right

        case .originallyAvailableAt, .episodeAirDate:
            let left = lhs.metadata?.originallyAvailableAt ?? lhs.metadata?.addedAt ?? .distantPast
            let right = rhs.metadata?.originallyAvailableAt ?? rhs.metadata?.addedAt ?? .distantPast
            return ascending ? left < right : left > right

        case .rating, .criticRating:
            let left = lhs.metadata?.rating ?? 0
            let right = rhs.metadata?.rating ?? 0
            return ascending ? left < right : left > right

        case .audienceRating:
            let left = lhs.metadata?.audienceRating ?? 0
            let right = rhs.metadata?.audienceRating ?? 0
            return ascending ? left < right : left > right

        case .contentRating:
            let left = lhs.metadata?.contentRating ?? ""
            let right = rhs.metadata?.contentRating ?? ""
            return ascending ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending : left.localizedCaseInsensitiveCompare(right) == .orderedDescending

        case .addedAt:
            let left = lhs.metadata?.addedAt ?? .distantPast
            let right = rhs.metadata?.addedAt ?? .distantPast
            return ascending ? left < right : left > right

        case .lastViewedAt:
            let left = lhs.metadata?.lastViewedAt ?? .distantPast
            let right = rhs.metadata?.lastViewedAt ?? .distantPast
            return ascending ? left < right : left > right

        case .viewCount:
            let left = lhs.metadata?.viewCount ?? 0
            let right = rhs.metadata?.viewCount ?? 0
            return ascending ? left < right : left > right

        case .unviewed:
            let left = (lhs.metadata?.viewCount ?? 0) == 0 ? 1 : 0
            let right = (rhs.metadata?.viewCount ?? 0) == 0 ? 1 : 0
            return ascending ? left < right : left > right

        case .random:
            return false
        }
    }
}

extension Channel.Provenance: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case libraryKey
        case identifier
        case draft
    }

    private enum Kind: String, Codable {
        case library
        case seed
        case filters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .library:
            let key = try container.decode(String.self, forKey: .libraryKey)
            self = .library(key: key)
        case .seed:
            let identifier = try container.decode(String.self, forKey: .identifier)
            self = .seed(identifier: identifier)
        case .filters:
            let draft = try container.decode(ChannelDraft.self, forKey: .draft)
            self = .filters(draft)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .library(let key):
            try container.encode(Kind.library, forKey: .kind)
            try container.encode(key, forKey: .libraryKey)
        case .seed(let identifier):
            try container.encode(Kind.seed, forKey: .kind)
            try container.encode(identifier, forKey: .identifier)
        case .filters(let draft):
            try container.encode(Kind.filters, forKey: .kind)
            try container.encode(draft, forKey: .draft)
        }
    }
}
