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
    var onMenuStateChange: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            GroupEditor(
                group: $spec.rootGroup,
                level: 0,
                library: library,
                availableFields: availableFields,
                filterCatalog: filterCatalog,
                onGroupChange: { updatedGroup in
                    spec.rootGroup = updatedGroup
                },
                onMenuStateChange: onMenuStateChange
            )
        }
        .padding(.horizontal, 32)  // Container padding (2.5× shadow radius) to prevent clipping
        .padding(.vertical, 16)
        .onChange(of: spec) { _, newValue in
            onSpecChange(newValue)
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
    var onMenuStateChange: ((Bool) -> Void)?

    private let spacing: CGFloat = 20
    private let indent: CGFloat = 40
    
    @FocusState private var focusedButton: FocusedControlButton?
    
    private enum FocusedControlButton: Hashable {
        case modeToggle
        case addFilter
        case addGroup
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Control row: Mode toggle + Add buttons (fixed width buttons with proper spacing)
            HStack(spacing: 24) {
                // Toggle button for Match All/Any
                Button {
                    group.mode = group.mode == .all ? .any : .all
                    onGroupChange(group)
                } label: {
                    Text(group.mode == .all ? "Match all of the following" : "Match any of the following")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .frame(width: 340, alignment: .center)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(focusedButton == .modeToggle ? 0.15 : 0.10))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focusedButton, equals: .modeToggle)
                .scaleEffect(focusedButton == .modeToggle ? 1.015 : 1.0)
                .shadow(color: focusedButton == .modeToggle ? .accentColor.opacity(0.3) : .clear, radius: 8, x: 0, y: 2)
                .animation(.easeInOut(duration: 0.15), value: focusedButton == .modeToggle)
                
                // Add Filter button
                Button {
                    addFilter()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .imageScale(.small)
                        Text("Add Filter")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .frame(width: 220)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(focusedButton == .addFilter ? 0.15 : 0.10))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focusedButton, equals: .addFilter)
                .scaleEffect(focusedButton == .addFilter ? 1.015 : 1.0)
                .shadow(color: focusedButton == .addFilter ? .accentColor.opacity(0.3) : .clear, radius: 8, x: 0, y: 2)
                .animation(.easeInOut(duration: 0.15), value: focusedButton == .addFilter)
                
                // Add Group button
                Button {
                    addGroup()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "ellipsis")
                            .imageScale(.small)
                        Text("Add Group")
                            .font(.callout)
                            .lineLimit(1)
                    }
                    .frame(width: 220)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(focusedButton == .addGroup ? 0.15 : 0.10))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focusedButton, equals: .addGroup)
                .scaleEffect(focusedButton == .addGroup ? 1.015 : 1.0)
                .shadow(color: focusedButton == .addGroup ? .accentColor.opacity(0.3) : .clear, radius: 8, x: 0, y: 2)
                .animation(.easeInOut(duration: 0.15), value: focusedButton == .addGroup)
            }
            .padding(.leading, CGFloat(level) * indent)

            // Rules - full width with indent
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
                    },
                    onRuleChange: {
                        onGroupChange(group)
                    },
                    onMenuStateChange: onMenuStateChange
                )
                .padding(.leading, CGFloat(level) * indent)
            }

            // Nested groups with background
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
                    .padding(.leading, CGFloat(level + 1) * indent)
                }
                .padding(.top, spacing)
                .padding(16)
                .padding(.leading, CGFloat(level) * indent)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
        // Only add background/padding for nested groups (level > 0)
        .if(level > 0) { view in
            view
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
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
    var onRuleChange: (() -> Void)?
    var onMenuStateChange: ((Bool) -> Void)?

    @State private var enumOptions: [FilterOption] = []
    @State private var isLoadingOptions = false
    @State private var numericString: String = ""
    @State private var textValue: String = ""
    @State private var dateValue: Date = Date()
    @State private var relativePreset: RelativeDatePreset = .last30Days
    
    @FocusState private var focusedField: FocusedRuleField?
    @State private var isMenuOpen = false
    
    private enum FocusedRuleField: Hashable {
        case fieldPicker
        case operatorPicker
        case valuePicker
        case trashButton
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            // Field picker - dropdown menu with focus handling
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
                HStack(spacing: 8) {
                    Text(rule.field.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 240, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(focusedField == .fieldPicker ? 0.18 : 0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: .fieldPicker)
            .scaleEffect(focusedField == .fieldPicker ? 1.015 : 1.0)
            .shadow(color: focusedField == .fieldPicker ? .accentColor.opacity(0.3) : .clear, radius: 6, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.15), value: focusedField == .fieldPicker)
            .onTapGesture {
                // Mark menu as open when tapped
                isMenuOpen = true
                onMenuStateChange?(true)
            }
            
            // Operator picker - dropdown menu with focus handling
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
                HStack(spacing: 8) {
                    Text(rule.op.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 240, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(focusedField == .operatorPicker ? 0.18 : 0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: .operatorPicker)
            .scaleEffect(focusedField == .operatorPicker ? 1.015 : 1.0)
            .shadow(color: focusedField == .operatorPicker ? .accentColor.opacity(0.3) : .clear, radius: 6, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.15), value: focusedField == .operatorPicker)
            .onTapGesture {
                // Mark menu as open when tapped
                isMenuOpen = true
                onMenuStateChange?(true)
            }

            // Value editor
            valueEditor

            // Delete button - with proper focus handling
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
                    .imageScale(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(width: 70, height: 50)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.red.opacity(focusedField == .trashButton ? 0.25 : 0.15))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: .trashButton)
            .scaleEffect(focusedField == .trashButton ? 1.015 : 1.0)
            .shadow(color: focusedField == .trashButton ? .red.opacity(0.4) : .clear, radius: 6, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.15), value: focusedField == .trashButton)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .task(id: rule.field) {
            await loadOptionsIfNeeded()
        }
        .onChange(of: rule.value) { _, _ in
            // Trigger count update when rule value changes
            AppLoggers.channel.info("event=builder.rules.change libraryID=\(library.uuid, privacy: .public) field=\(rule.field.id, privacy: .public) op=\(rule.op.rawValue, privacy: .public) action=valueChange")
            onRuleChange?()
        }
        .onChange(of: focusedField) { _, newValue in
            let isMenuOpen = newValue != nil
            self.isMenuOpen = isMenuOpen
            onMenuStateChange?(isMenuOpen)
            
            // If focus is lost, mark menu as closed
            if newValue == nil && self.isMenuOpen {
                self.isMenuOpen = false
                onMenuStateChange?(false)
            }
        }
        .onAppear {
            // Reset menu state when view appears
            self.isMenuOpen = false
            onMenuStateChange?(false)
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.field.valueKind {
        case .text:
            TextField("Value", text: bindingForText())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 300)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        case .number:
            TextField("Value", text: bindingForNumber())
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(width: 180)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
        case .boolean:
            Toggle("True", isOn: bindingForBool())
                .toggleStyle(.switch)
                .frame(width: 180)
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
            // Dropdown menu for enum values with focus handling
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
                HStack(spacing: 8) {
                    if isLoadingOptions {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Text(enumDisplayValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .frame(width: 300, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(focusedField == .valuePicker ? 0.18 : 0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .focused($focusedField, equals: .valuePicker)
            .scaleEffect(focusedField == .valuePicker ? 1.015 : 1.0)
            .shadow(color: focusedField == .valuePicker ? .accentColor.opacity(0.3) : .clear, radius: 6, x: 0, y: 2)
            .animation(.easeInOut(duration: 0.15), value: focusedField == .valuePicker)
            .onTapGesture {
                // Mark menu as open when tapped
                isMenuOpen = true
                onMenuStateChange?(true)
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
                // Sanitize text input to remove invisible characters that can break filtering
                let sanitized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{FFFC}", with: "") // Object replacement character
                    .replacingOccurrences(of: "\u{200B}", with: "") // Zero-width space
                    .replacingOccurrences(of: "\u{200C}", with: "") // Zero-width non-joiner
                    .replacingOccurrences(of: "\u{200D}", with: "") // Zero-width joiner
                    .replacingOccurrences(of: "\u{FEFF}", with: "") // Zero-width no-break space
                
                textValue = sanitized
                rule.value = .text(sanitized)
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
                // Sanitize text input to remove invisible characters that can break filtering
                let sanitized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\u{FFFC}", with: "") // Object replacement character
                    .replacingOccurrences(of: "\u{200B}", with: "") // Zero-width space
                    .replacingOccurrences(of: "\u{200C}", with: "") // Zero-width non-joiner
                    .replacingOccurrences(of: "\u{200D}", with: "") // Zero-width joiner
                    .replacingOccurrences(of: "\u{FEFF}", with: "") // Zero-width no-break space
                
                numericString = sanitized
                if let double = Double(sanitized) {
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

// View extension for conditional modifiers
private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
