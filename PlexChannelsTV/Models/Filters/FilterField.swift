//
//  FilterField.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation
import PlexKit

enum FilterValueKind: String, Codable {
    case text
    case number
    case date
    case enumSingle
    case enumMulti
    case boolean
}

enum FilterMediaScope: String, CaseIterable, Codable {
    case movie
    case show
    case episode

    init(type: PlexMediaType) {
        switch type {
        case .movie:
            self = .movie
        case .show:
            self = .show
        default:
            self = .episode
        }
    }
}

/// Describes a field a user can filter on in the channel builder.
enum FilterField: String, CaseIterable, Codable, Hashable, Identifiable {
    case title
    case showTitle
    case studio
    case network
    case country
    case collection
    case label
    case genre
    case contentRating
    case year
    case decade
    case rating
    case audienceRating
    case plays
    case unwatched
    case inProgress
    case duplicate
    case unmatched
    case dateAdded
    case dateViewed
    case episodeAirDate
    case lastWatched
    case resolution
    case hdr
    case dovi
    case audioLanguage
    case subtitleLanguage
    case actor
    case director
    case writer
    case duration

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .title:            return "Title"
        case .showTitle:        return "Show Title"
        case .studio:           return "Studio"
        case .network:          return "Network"
        case .country:          return "Country"
        case .collection:       return "Collection"
        case .label:            return "Label"
        case .genre:            return "Genre"
        case .contentRating:    return "Content Rating"
        case .year:             return "Year"
        case .decade:           return "Decade"
        case .rating:           return "Critic Rating"
        case .audienceRating:   return "Audience Rating"
        case .plays:            return "Plays"
        case .unwatched:        return "Unwatched"
        case .inProgress:       return "In Progress"
        case .duplicate:        return "Duplicate"
        case .unmatched:        return "Unmatched"
        case .dateAdded:        return "Date Added"
        case .dateViewed:       return "Date Viewed"
        case .episodeAirDate:   return "Episode Air Date"
        case .lastWatched:      return "Last Watched"
        case .resolution:       return "Resolution"
        case .hdr:              return "HDR"
        case .dovi:             return "Dolby Vision"
        case .audioLanguage:    return "Audio Language"
        case .subtitleLanguage: return "Subtitle Language"
        case .actor:            return "Actor"
        case .director:         return "Director"
        case .writer:           return "Writer"
        case .duration:         return "Duration"
        }
    }

    var valueKind: FilterValueKind {
        switch self {
        case .title, .showTitle, .studio, .network, .actor, .director, .writer:
            return .text
        case .collection, .label, .genre, .contentRating, .country, .audioLanguage, .subtitleLanguage, .resolution:
            return .enumMulti
        case .hdr, .dovi, .unwatched, .inProgress, .duplicate, .unmatched:
            return .boolean
        case .year, .decade, .rating, .audienceRating, .plays, .duration:
            return .number
        case .dateAdded, .dateViewed, .episodeAirDate, .lastWatched:
            return .date
        }
    }

    var supportedOperators: [FilterOperator] {
        switch valueKind {
        case .text:
            return [.contains, .notContains, .equals, .notEquals, .beginsWith, .endsWith]
        case .enumSingle, .enumMulti:
            return [.equals, .notEquals]
        case .number:
            return [.lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .equals, .notEquals]
        case .date:
            return [.before, .on, .after]
        case .boolean:
            return [.equals, .notEquals]
        }
    }

    var appliesTo: [FilterMediaScope] {
        switch self {
        case .title, .genre, .collection, .label, .contentRating, .year, .decade, .rating, .audienceRating, .plays, .unwatched, .inProgress, .duplicate, .unmatched, .dateAdded, .dateViewed, .lastWatched, .resolution, .hdr, .dovi, .audioLanguage, .subtitleLanguage, .actor, .director, .writer, .duration, .country, .studio:
            return [.movie, .show, .episode]
        case .showTitle:
            return [.episode]
        case .network:
            return [.show, .episode]
        case .episodeAirDate:
            return [.episode]
        }
    }

    func applies(to scope: FilterMediaScope) -> Bool {
        appliesTo.contains(scope)
    }

    func applies(to mediaType: PlexMediaType) -> Bool {
        applies(to: FilterMediaScope(type: mediaType))
    }
}
