//
//  LibraryMultiPickerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/01/25.
//

import SwiftUI
import PlexKit

struct LibraryMultiPickerView: View {
    let libraries: [PlexLibrary]
    let selectedIDs: Set<String>
    var onToggle: (PlexLibrary) -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(libraries, id: \.uuid) { library in
                    LibraryCard(library: library, isSelected: selectedIDs.contains(library.uuid)) {
                        onToggle(library)
                    }
                }
            }
            .padding(.vertical, 16)
        }
    }
}

private struct LibraryCard: View {
    let library: PlexLibrary
    let isSelected: Bool
    var action: () -> Void

    @State private var isFocused = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: iconName(for: library.type))
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                }
                Text(library.title ?? "Library")
                    .font(.headline)
                    .lineLimit(2)
                Text(library.type.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(minHeight: 140)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusableCompat { focused in
            withAnimation(.easeInOut(duration: 0.18)) {
                isFocused = focused
            }
        }
        .scaleEffect(isFocused ? 1.05 : 1.0)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused || isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .shadow(color: isFocused ? Color.accentColor.opacity(0.35) : .clear, radius: 14, x: 0, y: 4)
    }

    private func iconName(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film.fill"
        case .show, .episode:
            return "tv.fill"
        case .artist, .album, .track:
            return "music.note.list"
        default:
            return "play.rectangle.fill"
        }
    }
}

extension PlexMediaType {
    var displayName: String {
        switch self {
        case .movie:
            return "Movies"
        case .show:
            return "Shows"
        case .episode:
            return "Episodes"
        default:
            return rawValue.capitalized
        }
    }
}
