//
//  LibraryPickerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import SwiftUI
import PlexKit

struct LibraryPickerView: View {
    let libraries: [PlexLibrary]
    var onLibraryChosen: (PlexLibrary) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(libraries, id: \.uuid) { library in
                    FocusableLibraryRow(library: library) {
                        onLibraryChosen(library)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Choose a Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func iconName(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film.fill"
        case .show, .season, .episode:
            return "tv.fill"
        case .artist, .album, .track:
            return "music.note.list"
        case .photo, .picture, .photoAlbum:
            return "photo.fill.on.rectangle.fill"
        default:
            return "play.rectangle.fill"
        }
    }
}

private struct FocusableLibraryRow: View {
    let library: PlexLibrary
    var action: () -> Void

    @State private var isFocused = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: iconName(for: library.type))
                    .foregroundColor(.accentColor)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.title ?? "Library")
                        .font(.headline)
                    Text(library.type.rawValue.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 3)
                    .shadow(color: isFocused ? Color.accentColor.opacity(0.4) : .clear, radius: 10)
            )
        }
        .buttonStyle(.plain)
        .focusableCompat { focused in
            withAnimation(.easeInOut(duration: 0.2)) {
                isFocused = focused
            }
        }
        .scaleEffect(isFocused ? 1.03 : 1.0)
    }

    private func iconName(for type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film.fill"
        case .show, .season, .episode:
            return "tv.fill"
        case .artist, .album, .track:
            return "music.note.list"
        case .photo, .picture, .photoAlbum:
            return "photo.fill.on.rectangle.fill"
        default:
            return "play.rectangle.fill"
        }
    }
}
