//
//  FilterFieldResolver.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

enum FilterFieldResolver {
    static func stringValue(_ field: FilterField, from item: PlexMediaItem) -> String? {
        switch field {
        case .title:
            if item.type == .episode {
                return item.grandparentTitle ?? item.title
            }
            return item.title
        case .showTitle:
            return item.grandparentTitle ?? item.title
        case .studio, .network:
            return item.studio
        default:
            return nil
        }
    }

    static func stringValues(_ field: FilterField, from item: PlexMediaItem) -> [String] {
        switch field {
        case .genre:
            return item.genres.map(\.tag)
        case .collection:
            return []
        case .label:
            return []
        case .country:
            return item.countries.map(\.tag)
        case .contentRating:
            if let rating = item.contentRating {
                return [rating]
            }
            return []
        case .audioLanguage:
            return audioStreams(from: item).compactMap { $0.languageCode ?? $0.language }
        case .subtitleLanguage:
            return subtitleStreams(from: item).compactMap { $0.languageCode ?? $0.language }
        case .resolution:
            return item.media.compactMap(\.videoResolution)
        case .actor:
            return item.roles.map(\.tag)
        case .director:
            return item.directors.map(\.tag)
        case .writer:
            return item.writers.map(\.tag)
        default:
            return []
        }
    }

    static func numberValue(_ field: FilterField, from item: PlexMediaItem) -> Double? {
        switch field {
        case .year:
            return item.year.map(Double.init)
        case .decade:
            return item.year.map { Double(($0 / 10) * 10) }
        case .rating:
            return item.rating
        case .audienceRating:
            return item.userRating
        case .plays:
            return item.viewCount.map(Double.init)
        case .duration:
            return item.duration.map { Double($0) / 60.0 } // minutes
        default:
            return nil
        }
    }

    static func dateValue(_ field: FilterField, from item: PlexMediaItem) -> Date? {
        switch field {
        case .dateAdded:
            return item.addedAt
        case .dateViewed, .lastWatched:
            return item.lastViewedAt
        case .showLastWatched:
            // For show-level filtering, return the show's lastViewedAt (when item is a show)
            // For episodes, we'd need to fetch the show's metadata, but this is handled
            // in the two-step filtering process where showLastWatched filters shows first
            return item.lastViewedAt
        case .dateReleased:
            return item.originallyReleasedAt
        case .episodeAirDate:
            return item.originallyReleasedAt
        default:
            return nil
        }
    }

    static func boolValue(_ field: FilterField, from item: PlexMediaItem) -> Bool? {
        switch field {
        case .unwatched:
            // Use lastViewedAt as primary indicator - if it's nil, item is unwatched
            // Fallback to viewCount if lastViewedAt is not available
            if item.lastViewedAt != nil {
                return false // Has been viewed
            } else {
                return (item.viewCount ?? 0) == 0
            }
        case .inProgress:
            if let duration = item.duration, duration > 0, let progress = item.viewOffset {
                return progress > 0 && progress < duration
            }
            return false
        default:
            return nil
        }
    }

    static func audioStreams(from item: PlexMediaItem) -> [PlexMediaItem.Stream] {
        item.media.flatMap(\.parts).flatMap(\.streams).filter { $0.type == .audio }
    }

    static func subtitleStreams(from item: PlexMediaItem) -> [PlexMediaItem.Stream] {
        item.media.flatMap(\.parts).flatMap(\.streams).filter { $0.type == .subtitle }
    }
}
