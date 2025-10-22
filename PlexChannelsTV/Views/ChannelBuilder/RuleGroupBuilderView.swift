//
//  RuleGroupBuilderView.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI
import PlexKit

struct RuleGroupBuilderView: View {
    @Binding var spec: LibraryFilterSpec
    let library: PlexLibrary
    let availableFields: [FilterField]
    let filterCatalog: PlexFilterCatalog
    let countState: ChannelBuilderViewModel.CountState?
    var onSpecChange: (LibraryFilterSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupEditor(
                        group: $spec.rootGroup,
                        level: 0,
                        library: library,
                        availableFields: availableFields,
                        filterCatalog: filterCatalog,
                        onGroupChange: { updatedGroup in
                            spec.rootGroup = updatedGroup
                        }
                    )
                }
                .padding(.vertical, 10)
            }
        }
        .onChange(of: spec) { _, newValue in
            onSpecChange(newValue)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(library.title ?? "Library")
                    .font(.title3.bold())
                Text(library.type.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let countState {
                CountBadge(state: countState)
            }
        }
    }
}

private struct GroupEditor: View {
    @Binding var group: FilterGroup
    let level: Int
    let library: PlexLibrary
    let availableFields: [FilterField]
    let filterCatalog: PlexFilterCatalog
    var onGroupChange: (FilterGroup) -> Void

    private let spacing: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Control row: Mode toggle + Add buttons
            HStack(spacing: 12) {
                // Toggle button for Match All/Any
                Button {
                    group.mode = group.mode == .all ? .any : .all
                    onGroupChange(group)
                } label: {
                    Text(group.mode == .all ? "Match all of the following" : "Match any of the following")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                
                // Add Filter button
                Button {
                    addFilter()
                } label: {
                    Image(systemName: "plus")
                        .imageScale(.small)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                
                // Add Group button
                Button {
                    addGroup()
                } label: {
                    Image(systemName: "ellipsis")
                        .imageScale(.small)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
            .padding(.leading, CGFloat(level) * 12)

            // Rules
            ForEach($group.rules) { $rule in
                FilterRuleEditor(
                    rule: $rule,
                    library: library,
                    availableFields: availableFields,
                    filterCatalog: filterCatalog,
                    onRemove: {
                        if let index = group.rules.firstIndex(where: { $0.id == rule.id }) {
                            let removed = group.rules[index]
                            AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(removed.field.id, privacy: .public) op=\(removed.op.rawValue, privacy: .public) action=remove")
                            group.rules.remove(at: index)
                            onGroupChange(group)
                        }
                    }
                )
                .padding(.leading, CGFloat(level) * 12)
            }

            // Nested groups
            ForEach($group.groups) { $subgroup in
                VStack(alignment: .leading, spacing: spacing) {
                    GroupEditor(
                        group: $subgroup,
                        level: level + 1,
                        library: library,
                        availableFields: availableFields,
                        filterCatalog: filterCatalog,
                        onGroupChange: { updated in
                            if let idx = group.groups.firstIndex(where: { $0.id == updated.id }) {
                                group.groups[idx] = updated
                                onGroupChange(group)
                            }
                        }
                    )
                    Button(role: .destructive) {
                        if let index = group.groups.firstIndex(where: { $0.id == subgroup.id }) {
                            AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=group action=remove")
                            group.groups.remove(at: index)
                            onGroupChange(group)
                        }
                    } label: {
                        Label("Remove Group", systemImage: "trash")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, CGFloat(level + 1) * 12)
                }
                .padding(.top, spacing)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }
    
    private func addFilter() {
        let field = availableFields.first ?? .title
        let op = field.supportedOperators.first ?? .equals
        let initialValue: FilterValue
        switch field.valueKind {
        case .text:
            initialValue = .text("")
        case .number:
            initialValue = .number(0)
        case .boolean:
            initialValue = .boolean(true)
        case .date:
            initialValue = .date(Date())
        case .enumMulti, .enumSingle:
            initialValue = .enumSet([])
        }
        let newRule = FilterRule(field: field, op: op, value: initialValue)
        group.rules.append(newRule)
        AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(field.id, privacy: .public) op=\(op.rawValue, privacy: .public) action=add")
        onGroupChange(group)
    }
    
    private func addGroup() {
        var newGroup = FilterGroup(mode: .all)
        let field = availableFields.first ?? .title
        let op = field.supportedOperators.first ?? .equals
        newGroup.rules.append(FilterRule(field: field, op: op, value: .text("")))
        group.groups.append(newGroup)
        AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=group action=add")
        onGroupChange(group)
    }
}

private struct FilterRuleEditor: View {
    @Binding var rule: FilterRule
    let library: PlexLibrary
    let availableFields: [FilterField]
    let filterCatalog: PlexFilterCatalog
    var onRemove: () -> Void

    @State private var enumOptions: [FilterOption] = []
    @State private var isLoadingOptions = false
    @State private var numericString: String = ""
    @State private var textValue: String = ""
    @State private var dateValue: Date = Date()
    @State private var relativePreset: RelativeDatePreset = .last30Days

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Field picker - dropdown menu
            Menu {
                ForEach(availableFields, id: \.self) { field in
                    Button {
                        rule.field = field
                        AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(field.id, privacy: .public) op=\(rule.op.rawValue, privacy: .public)")
                        resetValue(for: field)
                    } label: {
                        Text(field.displayName)
                    }
                }
            } label: {
                HStack {
                    Text(rule.field.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 200, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            
            // Operator picker - dropdown menu
            Menu {
                ForEach(rule.field.supportedOperators, id: \.self) { op in
                    Button {
                        rule.op = op
                        AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(rule.field.id, privacy: .public) op=\(op.rawValue, privacy: .public)")
                    } label: {
                        Text(op.displayName)
                    }
                }
            } label: {
                HStack {
                    Text(rule.op.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 180, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            // Value editor
            valueEditor

            // Delete button
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
        }
        .task(id: rule.field) {
            await loadOptionsIfNeeded()
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.field.valueKind {
        case .text:
            TextField("Value", text: bindingForText())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(width: 280)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        case .number:
            TextField("Value", text: bindingForNumber())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(width: 160)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        case .boolean:
            Toggle("True", isOn: bindingForBool())
                .toggleStyle(.switch)
                .frame(width: 160)
        case .date:
            DateValuePicker(
                selection: bindingForDate(),
                preset: $relativePreset,
                onPresetChange: { preset in
                    rule.value = .relativeDate(preset)
                }
            )
            .frame(width: 280)
        case .enumMulti, .enumSingle:
            // Dropdown menu for enum values
            Menu {
                if isLoadingOptions {
                    Text("Loading...")
                } else if enumOptions.isEmpty {
                    Text("No options available")
                } else {
                    ForEach(enumOptions) { option in
                        Button {
                            toggleEnumValue(option.value)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                if selectionValues().contains(option.value) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack {
                    if isLoadingOptions {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Text(enumDisplayValue)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 280, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func bindingForText() -> Binding<String> {
        Binding(
            get: {
                switch rule.value {
                case .text(let value):
                    return value
                case .enumCase(let value):
                    return value
                default:
                    return textValue
                }
            },
            set: { newValue in
                textValue = newValue
                rule.value = .text(newValue)
            }
        )
    }

    private func bindingForNumber() -> Binding<String> {
        Binding(
            get: {
                switch rule.value {
                case .number(let value):
                    return numericString.isEmpty ? trimTrailingZeros(String(value)) : numericString
                case .text(let string):
                    return string
                default:
                    return numericString
                }
            },
            set: { newValue in
                numericString = newValue
                if let double = Double(newValue) {
                    rule.value = .number(double)
                }
            }
        )
    }

    private func bindingForBool() -> Binding<Bool> {
        Binding(
            get: {
                switch rule.value {
                case .boolean(let bool):
                    return bool
                case .text(let string):
                    return string.lowercased() == "true"
                default:
                    return true
                }
            },
            set: { newValue in
                rule.value = .boolean(newValue)
            }
        )
    }

    private func bindingForDate() -> Binding<Date> {
        Binding(
            get: {
                switch rule.value {
                case .date(let date):
                    return date
                case .relativeDate(let preset):
                    if relativePreset != preset {
                        relativePreset = preset
                    }
                    return preset.resolveRange().lowerBound
                default:
                    return dateValue
                }
            },
            set: { newValue in
                dateValue = newValue
                rule.value = .date(newValue)
            }
        )
    }

    private func loadOptionsIfNeeded() async {
        guard rule.field.valueKind == .enumMulti || rule.field.valueKind == .enumSingle else { return }
        guard enumOptions.isEmpty else { return }
        isLoadingOptions = true
        defer { isLoadingOptions = false }
        do {
            enumOptions = try await filterCatalog.options(for: rule.field, in: library)
        } catch {
            isLoadingOptions = false
        }
    }

    private func selectionValues() -> [String] {
        switch rule.value {
        case .enumSet(let values):
            return values
        case .enumCase(let value):
            return [value]
        case .text(let value):
            return [value]
        default:
            return []
        }
    }
    
    private func toggleEnumValue(_ value: String) {
        var currentValues = selectionValues()
        
        if rule.field.valueKind == .enumMulti {
            if currentValues.contains(value) {
                currentValues.removeAll { $0 == value }
            } else {
                currentValues.append(value)
            }
            rule.value = .enumSet(currentValues)
        } else {
            rule.value = .enumCase(value)
        }
    }

    private var enumDisplayValue: String {
        let values = selectionValues()
        guard !values.isEmpty else { return "Select..." }
        if values.count == 1, let first = values.first {
            return first
        }
        return "\(values.count) selected"
    }

    private func resetValue(for field: FilterField) {
        let op = field.supportedOperators.first ?? .equals
        rule.op = op
        switch field.valueKind {
        case .text:
            rule.value = .text("")
        case .number:
            rule.value = .number(0)
            numericString = ""
        case .boolean:
            rule.value = .boolean(true)
        case .date:
            let now = Date()
            rule.value = .date(now)
            dateValue = now
        case .enumMulti, .enumSingle:
            rule.value = .enumSet([])
            enumOptions = []
        }
    }

    private func trimTrailingZeros(_ string: String) -> String {
        guard string.contains(".") else { return string }
        var trimmed = string
        while trimmed.last == "0" {
            trimmed.removeLast()
        }
        if trimmed.last == "." {
            trimmed.removeLast()
        }
        return trimmed
    }
}

private struct CountBadge: View {
    let state: ChannelBuilderViewModel.CountState

    var body: some View {
        HStack(spacing: 8) {
            if state.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.8)
            }
            Text(countLabel)
                .font(.footnote.bold())
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.09))
        )
    }

    private var countLabel: String {
        if let total = state.total {
            return state.approximate ? "~\(total)" : "\(total) items"
        }
        return state.isLoading ? "Counting…" : "—"
    }
}
