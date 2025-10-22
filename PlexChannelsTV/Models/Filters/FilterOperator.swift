//
//  FilterOperator.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation

/// Supported logical operators for channel rules.
/// Raw values map to Plex query tokens where available.
enum FilterOperator: String, CaseIterable, Codable, Hashable, Identifiable {
    case contains
    case notContains
    case equals
    case notEquals
    case beginsWith
    case endsWith
    case lessThan = "lt"
    case lessThanOrEqual = "lte"
    case greaterThan = "gt"
    case greaterThanOrEqual = "gte"
    case before
    case on
    case after

    var id: String {
        rawValue
    }

    /// Human-readable label for UI presentation.
    var displayName: String {
        switch self {
        case .contains:           return "Contains"
        case .notContains:        return "Does Not Contain"
        case .equals:             return "Is"
        case .notEquals:          return "Is Not"
        case .beginsWith:         return "Begins With"
        case .endsWith:           return "Ends With"
        case .lessThan:           return "Less Than"
        case .lessThanOrEqual:    return "Less Than or Equal"
        case .greaterThan:        return "Greater Than"
        case .greaterThanOrEqual: return "Greater Than or Equal"
        case .before:             return "Before"
        case .on:                 return "On"
        case .after:              return "After"
        }
    }

    /// Whether the operator represents a negated comparison.
    var isNegated: Bool {
        switch self {
        case .notContains, .notEquals:
            return true
        default:
            return false
        }
    }

    /// Convenience to determine if the operator is numeric-comparable.
    var isNumericComparable: Bool {
        switch self {
        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual, .equals, .notEquals:
            return true
        default:
            return false
        }
    }

    /// Convenience to determine if the operator involves an ordered date comparison.
    var isDateComparable: Bool {
        switch self {
        case .before, .on, .after:
            return true
        default:
            return false
        }
    }
}
