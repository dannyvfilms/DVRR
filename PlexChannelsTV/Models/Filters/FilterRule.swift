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
    case relativeDateSpec(RelativeDateSpec)

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
    
    var debugDescription: String {
        switch self {
        case .text(let value):
            return "\"\(value)\""
        case .number(let value):
            return "\(value)"
        case .boolean(let value):
            return "\(value)"
        case .date(let value):
            return "\(value)"
        case .enumCase(let value):
            return "\"\(value)\""
        case .enumSet(let values):
            return "[\(values.map { "\"\($0)\"" }.joined(separator: ", "))]"
        case .relativeDate(let preset):
            return "\"\(preset.displayName)\""
        case .relativeDateSpec(let spec):
            return "\"\(spec.displayName)\""
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
        case relativeDateSpec
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
        case .relativeDateSpec:
            let value = try container.decode(RelativeDateSpec.self, forKey: .value)
            self = .relativeDateSpec(value)
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
        case .relativeDateSpec(let value):
            try container.encode(Kind.relativeDateSpec, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Time units for relative date operations
enum TimeUnit: String, CaseIterable, Codable, Hashable, Identifiable {
    case seconds
    case minutes
    case hours
    case days
    case weeks
    case months
    case years

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .seconds: return "Seconds"
        case .minutes: return "Minutes"
        case .hours: return "Hours"
        case .days: return "Days"
        case .weeks: return "Weeks"
        case .months: return "Months"
        case .years: return "Years"
        }
    }

    var singularDisplayName: String {
        switch self {
        case .seconds: return "Second"
        case .minutes: return "Minute"
        case .hours: return "Hour"
        case .days: return "Day"
        case .weeks: return "Week"
        case .months: return "Month"
        case .years: return "Year"
        }
    }

    /// Convert a value in this unit to seconds
    func toSeconds(_ value: Int) -> TimeInterval {
        switch self {
        case .seconds: return TimeInterval(value)
        case .minutes: return TimeInterval(value * 60)
        case .hours: return TimeInterval(value * 3600)
        case .days: return TimeInterval(value * 86400)
        case .weeks: return TimeInterval(value * 604800)
        case .months: return TimeInterval(value * 2629746) // ~30.44 days
        case .years: return TimeInterval(value * 31556952) // ~365.25 days
        }
    }
}

/// Flexible relative date specification with custom time units
struct RelativeDateSpec: Codable, Hashable, Identifiable {
    let id: UUID
    let value: Int
    let unit: TimeUnit

    init(id: UUID = UUID(), value: Int, unit: TimeUnit) {
        self.id = id
        self.value = value
        self.unit = unit
    }

    var displayName: String {
        if value == 1 {
            return "1 \(unit.singularDisplayName)"
        } else {
            return "\(value) \(unit.displayName)"
        }
    }

    /// Calculate the date that is this duration ago from now
    var dateAgo: Date {
        Date().addingTimeInterval(-unit.toSeconds(value))
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
