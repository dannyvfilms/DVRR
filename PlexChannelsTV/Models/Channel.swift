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

    /// Returns the media item and playback offset for a given point in time.
    func playbackState(at date: Date = .init()) -> (media: Media, offset: TimeInterval)? {
        guard !items.isEmpty else { return nil }

        let loopDuration = totalDuration
        guard loopDuration > 0 else { return nil }

        let elapsed = max(0, date.timeIntervalSince(scheduleAnchor))
        let position = elapsed.truncatingRemainder(dividingBy: loopDuration)

        var cumulative: TimeInterval = 0
        for media in items {
            let nextCumulative = cumulative + max(0, media.duration)
            if position < nextCumulative {
                return (media, position - cumulative)
            }
            cumulative = nextCumulative
        }

        // Fallback to last item if rounding errors occur.
        guard let last = items.last else {
            return nil
        }
        return (last, 0)
    }

    func nowPlaying(at date: Date = .init()) -> Media? {
        playbackState(at: date)?.media
    }

    func nowPlayingTitle(at date: Date = .init()) -> String? {
        nowPlaying(at: date)?.title
    }
}
