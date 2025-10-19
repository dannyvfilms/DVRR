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

        init(
            id: String,
            title: String,
            duration: TimeInterval,
            metadataKey: String? = nil,
            partKey: String? = nil,
            partID: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.duration = duration
            self.metadataKey = metadataKey
            self.partKey = partKey
            self.partID = partID
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
            partID: firstPart?.id
        )
    }
}
