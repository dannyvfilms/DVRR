//
//  ChannelWizardView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import SwiftUI
import PlexKit

struct ChannelWizardView: View {
    let library: PlexLibrary
    var onComplete: (Channel) -> Void
    var onCancel: () -> Void

    @EnvironmentObject private var plexService: PlexService
    @EnvironmentObject private var channelStore: ChannelStore

    @State private var channelName: String
    @State private var shuffle = false
    @State private var step = 0

    @State private var mediaItems: [Channel.Media] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(library: PlexLibrary, onComplete: @escaping (Channel) -> Void, onCancel: @escaping () -> Void) {
        self.library = library
        self.onComplete = onComplete
        self.onCancel = onCancel
        _channelName = State(initialValue: library.title ?? "Channel")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                switch step {
                case 0:
                    configurationStep
                default:
                    previewStep
                }

                Spacer()

                HStack {
                    Button("Back") {
                        if step == 0 {
                            onCancel()
                        } else {
                            step = max(0, step - 1)
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    if step == 0 {
                    Button("Next") {
                        step = 1
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || mediaItems.isEmpty || channelStore.containsChannel(for: library))
                    } else {
                        Button("Create Channel") {
                            Task { await createChannel() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(mediaItems.isEmpty || isLoading)
                    }
                }
            }
            .padding()
            .navigationTitle("Create Channel")
            .task {
                await loadMediaItems()
            }
        }
    }

    private var configurationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 1 · Configure")
                .font(.title3)

            TextField("Channel Name", text: $channelName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 480)

            Toggle("Shuffle order", isOn: $shuffle)

            Text("Start time: Now")
                .font(.callout)
                .foregroundStyle(.secondary)

            if channelStore.containsChannel(for: library) {
                Text("A channel for this library already exists.")
                    .foregroundStyle(.red)
            }

            if isLoading {
                ProgressView("Loading library…")
            }
        }
    }

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step 2 · Preview")
                .font(.title3)

            if isLoading {
                ProgressView("Preparing preview…")
            } else if mediaItems.isEmpty {
                Text("No playable items were found in this library.")
                    .foregroundStyle(.secondary)
            } else {
                let previewChannel = makePreviewChannel()
                if let playback = previewChannel.playbackState() {
                    let remaining = previewChannel.timeRemaining() ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If you tuned in now:")
                            .font(.headline)
                        Text(playback.media.title)
                            .font(.title2)
                        Text("Elapsed \(formatted(time: playback.offset)) · \(formatted(time: remaining)) left")
                            .foregroundStyle(.secondary)
                    }
                }

                if let next = previewChannel.nextUp() {
                    Text("Up Next: \(next.title)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func loadMediaItems() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let items = try await plexService.fetchLibraryItems(for: library, limit: 500)
            let medias = items.compactMap(Channel.Media.from)
            await MainActor.run {
                self.mediaItems = medias
                if medias.isEmpty {
                    self.errorMessage = "No playable media items were found."
                }
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func createChannel() async {
        guard !mediaItems.isEmpty else { return }
        guard !channelStore.containsChannel(for: library) else {
            errorMessage = "A channel for this library already exists."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let channel = try await channelStore.createChannel(
                named: channelName,
                from: library,
                shuffle: shuffle,
                startAt: Date(),
                using: plexService
            )
            print("[ChannelWizard] Created channel '\(channel.name)' with \(channel.items.count) items")
            onComplete(channel)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makePreviewChannel() -> Channel {
        var items = mediaItems
        if shuffle {
            items.shuffle()
        }
        return Channel(
            name: channelName,
            libraryKey: library.key,
            libraryType: library.type,
            scheduleAnchor: Date(),
            items: items
        )
    }

    private func formatted(time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
