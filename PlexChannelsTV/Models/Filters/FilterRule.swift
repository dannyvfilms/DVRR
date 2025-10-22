//
//  FilterRule.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import Foundation

/// Represents the concrete value used in a rule comparison.
enum FilterValue: Hashable {
    case text(String)
    case number(Double)
    case boolean(Bool)
    case date(Date)
    case enumCase(String)
    case enumSet([String])
    case relativeDate(RelativeDatePreset)

    var isEmpty: Bool {
        switch self {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .enumSet(let values):
            return values.isEmpty
        case .enumCase(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return false
        }
    }
}

extension FilterValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    private enum Kind: String, Codable {
        case text
        case number
        case boolean
        case date
        case enumCase
        case enumSet
        case relativeDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            let value = try container.decode(String.self, forKey: .value)
            self = .text(value)
        case .number:
            let value = try container.decode(Double.self, forKey: .value)
            self = .number(value)
        case .boolean:
            let value = try container.decode(Bool.self, forKey: .value)
            self = .boolean(value)
        case .date:
            let value = try container.decode(Date.self, forKey: .value)
            self = .date(value)
        case .enumCase:
            let value = try container.decode(String.self, forKey: .value)
            self = .enumCase(value)
        case .enumSet:
            let value = try container.decode([String].self, forKey: .value)
            self = .enumSet(value)
        case .relativeDate:
            let value = try container.decode(RelativeDatePreset.self, forKey: .value)
            self = .relativeDate(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .date(let value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .enumCase(let value):
            try container.encode(Kind.enumCase, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .enumSet(let value):
            try container.encode(Kind.enumSet, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .relativeDate(let value):
            try container.encode(Kind.relativeDate, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Convenience wrapper for date presets (e.g. "Last 30 days").
enum RelativeDatePreset: Codable, Hashable, Identifiable {
    case today
    case last7Days
    case last30Days
    case last90Days
    case last365Days
    case custom(days: Int)

    var id: String {
        switch self {
        case .today: return "today"
        case .last7Days: return "last7"
        case .last30Days: return "last30"
        case .last90Days: return "last90"
        case .last365Days: return "last365"
        case .custom(let days): return "custom:\(days)"
        }
    }

    var displayName: String {
        switch self {
        case .today:
            return "Today"
        case .last7Days:
            return "Last 7 Days"
        case .last30Days:
            return "Last 30 Days"
        case .last90Days:
            return "Last 90 Days"
        case .last365Days:
            return "Last 365 Days"
        case .custom(let days):
            return "Last \(days) Days"
        }
    }

    static var commonPresets: [RelativeDatePreset] {
        [.today, .last7Days, .last30Days, .last90Days, .last365Days]
    }
}

/// A single predicate in the rule group tree.
struct FilterRule: Identifiable, Codable, Hashable {
    let id: UUID
    var field: FilterField
    var op: FilterOperator
    var value: FilterValue

    init(
        id: UUID = UUID(),
        field: FilterField,
        op: FilterOperator,
        value: FilterValue
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}
