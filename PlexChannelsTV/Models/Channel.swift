//
//  Channel.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import Foundation
import PlexKit

struct Channel: Identifiable, Codable, Hashable {
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

    let id: UUID
    let name: String
    let libraryKey: String
    let libraryType: PlexMediaType
    let createdAt: Date
    /// Reference point for the start of the playlist loop.
    let scheduleAnchor: Date
    let items: [Media]

    init(
        id: UUID = UUID(),
        name: String,
        libraryKey: String,
        libraryType: PlexMediaType,
        createdAt: Date = Date(),
        scheduleAnchor: Date = Date(),
        items: [Media]
    ) {
        self.id = id
        self.name = name
        self.libraryKey = libraryKey
        self.libraryType = libraryType
        self.createdAt = createdAt
        self.scheduleAnchor = scheduleAnchor
        self.items = items
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
                guid: item.guid
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
