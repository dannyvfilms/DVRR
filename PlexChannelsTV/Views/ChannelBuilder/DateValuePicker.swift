//
//  DateValuePicker.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI

struct DateValuePicker: View {
    @Binding var selection: Date
    @Binding var preset: RelativeDatePreset
    var onPresetChange: (RelativeDatePreset) -> Void

    @State private var isShowingCalendar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Menu {
                ForEach(RelativeDatePreset.commonPresets, id: \.id) { option in
                    Button(option.displayName) {
                        preset = option
                        let range = option.resolveRange()
                        selection = range.lowerBound
                        onPresetChange(option)
                    }
                }
                Button("Custom Date") {
                    preset = .custom(days: 0)
                    isShowingCalendar = true
                }
            } label: {
                HStack {
                    Text(presetLabel)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
            }

            if preset.isCustom {
                Button {
                    isShowingCalendar = true
                } label: {
                    HStack {
                        Text(formattedSelection)
                        Spacer()
                        Image(systemName: "calendar")
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingCalendar) {
            CalendarPicker(selection: $selection)
        }
    }

    private var presetLabel: String {
        preset.isCustom ? "Custom" : preset.displayName
    }

    private var formattedSelection: String {
        selection.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct CalendarPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Date

    private let calendar = Calendar.current

    private var days: [Date] {
        let start = calendar.date(byAdding: .day, value: -365, to: Date()) ?? Date()
        return (0..<731).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
    }

    var body: some View {
        NavigationStack {
            List(days, id: \.self) { day in
                Button {
                    selection = day
                    dismiss()
                } label: {
                    HStack {
                        Text(day.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        if calendar.isDate(day, inSameDayAs: selection) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Select Date")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private extension RelativeDatePreset {
    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}
