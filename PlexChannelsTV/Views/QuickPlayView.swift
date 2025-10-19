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
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func startPlayback() async {
        guard let url = plexService.streamURL(for: item.media) else {
            playbackError = "Unable to construct a stream URL."
            return
        }

        print("[QuickPlay] Streaming \(item.title) via \(url.absoluteString)")
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
    }
}
