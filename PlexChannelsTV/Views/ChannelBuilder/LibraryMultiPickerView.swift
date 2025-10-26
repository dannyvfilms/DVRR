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
    let cacheStore: LibraryMediaCacheStore
    var onToggle: (PlexLibrary) -> Void

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 48) {
                ForEach(libraries, id: \.uuid) { library in
                    LibraryCard(library: library, isSelected: selectedIDs.contains(library.uuid), cacheStore: cacheStore) {
                        onToggle(library)
                    }
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 32)
        }
    }
}

private struct LibraryCard: View {
    let library: PlexLibrary
    let isSelected: Bool
    let cacheStore: LibraryMediaCacheStore
    var action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var cachedCount: Int? = nil

    var body: some View {
        Button(action: {
            AppLoggers.channel.info("event=builder.library.tap libraryID=\(library.uuid, privacy: .public) title=\(library.title ?? "unknown", privacy: .public)")
            action()
        }) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                
                // Content group (centered)
                HStack(alignment: .center, spacing: 32) {
                    // Icon on left
                    Image(systemName: iconName(for: library.type))
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                    
                    // Text stack in middle - much larger to fill icon height
                    VStack(alignment: .leading, spacing: 0) {
                        Text(library.title ?? "Library")
                            .font(.system(size: 32, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(height: 32)
                        
                        Spacer(minLength: 0).frame(height: 4)
                        
                        Text(subtitleText)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: 24)
                    }
                    .frame(height: 60)
                    .clipped()  // Hard clip at 60px
                    
                    // Checkmark on right
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                }
                
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(height: 120)
            .background(background)
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focused($isFocused)
        .scaleEffect(isFocused ? 1.015 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .shadow(color: isFocused ? Color.accentColor.opacity(0.3) : .clear, radius: 12, x: 0, y: 4)
        .onAppear {
            loadCachedCount()
        }
    }
    
    private var subtitleText: String {
        if let count = cachedCount {
            if library.type == .show {
                return "\(count) Episodes"
            } else {
                return "\(count) \(library.type.displayName)"
            }
        } else {
            return library.type.displayName
        }
    }
    
    private func loadCachedCount() {
        Task {
            let key = LibraryMediaCacheStore.CacheKey(
                libraryID: library.uuid,
                mediaType: library.type == .show ? .episode : library.type
            )
            let count = await cacheStore.itemCount(for: key)
            await MainActor.run {
                cachedCount = count
            }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isFocused || isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
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
