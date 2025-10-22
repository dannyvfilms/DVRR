//
//  SortDescriptor.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

struct SortDescriptor: Codable, Hashable {
    enum Order: String, Codable, Hashable {
        case ascending
        case descending

        var toggle: Order {
            self == .ascending ? .descending : .ascending
        }

        var displayName: String {
            switch self {
            case .ascending: return "Ascending"
            case .descending: return "Descending"
            }
        }
    }

    enum SortKey: String, Codable, Hashable, CaseIterable, Identifiable {
        case title
        case year
        case originallyAvailableAt
        case rating
        case audienceRating
        case criticRating
        case contentRating
        case addedAt
        case lastViewedAt
        case viewCount
        case unviewed
        case showTitle
        case episodeAirDate
        case random

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .title:                return "Title"
            case .year:                 return "Year"
            case .originallyAvailableAt:return "Release Date"
            case .rating:               return "Critic Rating"
            case .audienceRating:       return "Audience Rating"
            case .criticRating:         return "Critic Rating"
            case .contentRating:        return "Content Rating"
            case .addedAt:              return "Date Added"
            case .lastViewedAt:         return "Date Viewed"
            case .viewCount:            return "Plays"
            case .unviewed:             return "Unwatched"
            case .showTitle:            return "Show Title"
            case .episodeAirDate:       return "Episode Air Date"
            case .random:               return "Random"
            }
        }

        var supportsAscending: Bool {
            switch self {
            case .random:
                return false
            default:
                return true
            }
        }

        var defaultOrder: SortDescriptor.Order {
            switch self {
            case .addedAt, .lastViewedAt, .viewCount, .unviewed:
                return .descending
            default:
                return .ascending
            }
        }

        static func defaults(for type: PlexMediaType) -> [SortKey] {
            switch type {
            case .movie:
                return [.title, .year, .originallyAvailableAt, .rating, .audienceRating, .contentRating, .unviewed, .addedAt, .lastViewedAt, .random]
            case .episode:
                fallthrough
            case .show:
                return [.title, .showTitle, .episodeAirDate, .addedAt, .lastViewedAt, .viewCount, .unviewed, .random]
            default:
                return [.title, .addedAt, .random]
            }
        }
    }

    var key: SortKey
    var order: Order

    init(key: SortKey, order: Order = .ascending) {
        self.key = key
        self.order = order
    }

    static func `default`(for type: PlexMediaType) -> SortDescriptor {
        let keys = SortKey.defaults(for: type)
        guard let first = keys.first else {
            return SortDescriptor(key: .title, order: .ascending)
        }
        return SortDescriptor(key: first, order: first.defaultOrder)
    }
}
