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

    private let modeOptions: [FilterGroup.Mode] = [.all, .any]

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
            modeSelector

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

            Button {
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
            } label: {
                Label("Add Filter", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.leading, CGFloat(level) * 12)

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
                    }
                    .buttonStyle(.borderless)
                    .padding(.leading, CGFloat(level + 1) * 12)
                }
                .padding(.top, spacing)
            }

            Button {
                var newGroup = FilterGroup(mode: .all)
                let field = availableFields.first ?? .title
                let op = field.supportedOperators.first ?? .equals
                newGroup.rules.append(FilterRule(field: field, op: op, value: .text("")))
                group.groups.append(newGroup)
                AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=group action=add")
                onGroupChange(group)
            } label: {
                Label("Add Group", systemImage: "rectangle.3.group")
            }
            .buttonStyle(.borderless)
            .padding(.leading, CGFloat(level) * 12)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var modeSelector: some View {
        Picker("Mode", selection: $group.mode) {
            ForEach(FilterGroup.Mode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
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
    @State private var showEnumPicker = false
    @State private var numericString: String = ""
    @State private var textValue: String = ""
    @State private var dateValue: Date = Date()
    @State private var relativePreset: RelativeDatePreset = .last30Days

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Picker("Field", selection: $rule.field) {
                    ForEach(availableFields, id: \.self) { field in
                        Text(field.displayName).tag(field)
                    }
                }
                .frame(width: 220)

                Picker("Operator", selection: $rule.op) {
                    ForEach(rule.field.supportedOperators, id: \.self) { op in
                        Text(op.displayName).tag(op)
                    }
                }
                .frame(width: 220)

                valueEditor

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .onChange(of: rule.field) { _, newField in
            AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(newField.id, privacy: .public) op=\(rule.op.rawValue, privacy: .public)")
            resetValue(for: newField)
        }
        .onChange(of: rule.op) { _, newOp in
            AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(rule.field.id, privacy: .public) op=\(newOp.rawValue, privacy: .public)")
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
                .padding(.horizontal, 18)
                .frame(width: 320, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        case .number:
            TextField("Value", text: bindingForNumber())
                .padding(.horizontal, 18)
                .frame(width: 180, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
            .frame(width: 300)
        case .enumMulti, .enumSingle:
            Button {
                showEnumPicker = true
            } label: {
                HStack {
                    if isLoadingOptions {
                        ProgressView().progressViewStyle(.circular)
                    } else {
                        Text(enumDisplayValue)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                }
                .frame(width: 320, alignment: .leading)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showEnumPicker) {
                EnumSelectionView(
                    options: enumOptions,
                    selection: Binding(
                        get: { selectionValues() },
                        set: { updateEnumSelection($0) }
                    ),
                    allowsMultiple: rule.field.valueKind == .enumMulti
                )
            }
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

    private func updateEnumSelection(_ values: [String]) {
        if rule.field.valueKind == .enumMulti {
            rule.value = .enumSet(values)
        } else if let first = values.first {
            rule.value = .enumCase(first)
        }
    }

    private var enumDisplayValue: String {
        let values = selectionValues()
        guard !values.isEmpty else { return "Select" }
        return values.joined(separator: ", ")
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

private struct EnumSelectionView: View {
    let options: [FilterOption]
    @Binding var selection: [String]
    let allowsMultiple: Bool

    var body: some View {
        NavigationStack {
            if options.isEmpty {
                VStack(spacing: 16) {
                    Text("No options available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.01))
                .navigationTitle("Values")
            } else {
                List {
                    ForEach(options) { option in
                        Button {
                            toggle(option)
                        } label: {
                            HStack {
                                Text(option.displayName)
                                Spacer()
                                if selection.contains(option.value) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .navigationTitle(allowsMultiple ? "Select Values" : "Choose Value")
            }
        }
    }

    private func toggle(_ option: FilterOption) {
        if allowsMultiple {
            if selection.contains(option.value) {
                selection.removeAll { $0 == option.value }
            } else {
                selection.append(option.value)
            }
        } else {
            selection = [option.value]
        }
    }
}
