//
//  AddChannelView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI
import PlexKit
import Foundation

struct AddChannelView: View {
    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore
    @Environment(\.dismiss) private var dismiss

    var onChannelCreated: (Channel) -> Void = { _ in }

    @State private var creatingLibraryKey: String?
    @State private var activeAlert: AlertContent?

    private var availableLibraries: [PlexLibrary] {
        let libraries = plexService.session?.libraries ?? []
        return libraries.filter { !channelStore.containsChannel(for: $0) }
    }

    var body: some View {
        List {
            Section(header: Text("Select a Library")) {
                if availableLibraries.isEmpty {
                    Text("All available libraries already have channels.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(availableLibraries, id: \.uuid) { library in
                        Button {
                            createChannel(from: library)
                        } label: {
                            libraryRow(for: library)
                        }
                        .buttonStyle(.plain)
                        .focusable(true)
                        .disabled(creatingLibraryKey != nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Add Channel")
        .overlay {
            if creatingLibraryKey != nil {
                ProgressView("Creating Channel…")
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func libraryRow(for library: PlexLibrary) -> some View {
        HStack(spacing: 16) {
            Image(systemName: iconName(for: library.type))
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(library.title ?? "Unknown Library")
                    .font(.headline)
                Text(library.type.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if creatingLibraryKey == library.uuid {
                ProgressView()
            } else {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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
        case .collection:
            return "square.stack.3d.up.fill"
        default:
            return "play.rectangle.fill"
        }
    }

    private func createChannel(from library: PlexLibrary) {
        guard creatingLibraryKey == nil else { return }
        creatingLibraryKey = library.uuid

        Task { @MainActor in
            defer { creatingLibraryKey = nil }
            do {
                let channel = try await channelStore.createChannel(
                    named: library.title,
                    from: library,
                    shuffle: false,
                    startAt: Date(),
                    using: plexService
                )
                dismiss()
                DispatchQueue.main.async {
                    onChannelCreated(channel)
                }
            } catch let error as ChannelStore.ChannelCreationError {
                activeAlert = AlertContent(
                    title: "Channel Error",
                    message: error.errorDescription ?? "Unable to create channel."
                )
            } catch {
                activeAlert = AlertContent(
                    title: "Channel Error",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private struct AlertContent: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
