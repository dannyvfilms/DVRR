//
//  QuickPlayView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import SwiftUI
import AVKit

struct QuickPlayView: View {
    let item: LibraryPreviewItem

    @EnvironmentObject private var plexService: PlexService

    @State private var player: AVPlayer?
    @State private var playbackError: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let playbackError {
                VStack(spacing: 16) {
                    Text("Unable to play item")
                        .font(.title2)
                    Text(playbackError)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ProgressView("Loading…")
                    .progressViewStyle(.circular)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.title3)
                    .bold()
                Text("Quick Play Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding()
        }
        .task {
            await startPlayback()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackError != nil },
            set: { if !$0 { playbackError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playbackError ?? "An unknown error occurred")
        }
    }

    private func startPlayback() async {
        if let provided = item.streamURL {
            await MainActor.run {
                startPlayer(with: provided)
            }
            return
        }

        do {
            let url = try await plexService.quickPlayURL(for: item.media)
            await MainActor.run {
                startPlayer(with: url)
            }
        } catch {
            await MainActor.run {
                playbackError = error.localizedDescription
            }
        }
    }

    @MainActor
    private func startPlayer(with url: URL) {
        print("[QuickPlay] Streaming \(item.title) via \(url.absoluteString)")
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        player.play()
    }
}
