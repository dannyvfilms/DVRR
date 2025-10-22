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
    @State private var streamKind: PlexService.StreamKind?

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
                if let streamKind {
                    Text(streamKind == .direct ? "Direct Play" : "Transcode")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    @MainActor
    private func startPlayback() async {
        if let provided = item.streamURL {
            let descriptor = PlexService.StreamDescriptor(url: provided, kind: item.streamKind ?? .direct, offset: 0)
            startPlayer(with: descriptor)
            return
        }

        if let descriptor = plexService.streamDescriptor(for: item.media) ??
            plexService.streamDescriptor(for: item.media, preferTranscode: true) {
            startPlayer(with: descriptor)
        } else {
            playbackError = PlexService.PlaybackError.noStreamURL.errorDescription ?? "Unable to start playback."
        }
    }

    @MainActor
    private func startPlayer(with descriptor: PlexService.StreamDescriptor) {
        streamKind = descriptor.kind
        print("[QuickPlay] Streaming \(item.title) via \(descriptor.kind.rawValue) stream")
        let playerItem = AVPlayerItem(url: descriptor.url)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        player.play()
    }
}
