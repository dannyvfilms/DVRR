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
    var onSelect: (PlexLibrary) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(libraries, id: \.uuid) { library in
                    Button {
                        onSelect(library)
                    } label: {
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
                    }
                    .buttonStyle(.plain)
                    .focusable(true)
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
