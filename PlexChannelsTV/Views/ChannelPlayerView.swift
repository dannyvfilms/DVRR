//
//  ChannelPlayerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI
import AVKit

struct ChannelPlayerView: View {
    let channel: Channel

    @EnvironmentObject private var plexService: PlexService

    @State private var player: AVPlayer?
    @State private var playbackObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var currentPlayback: (media: Channel.Media, offset: TimeInterval)?
    @State private var playbackError: String?
    @State private var timer: Timer?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black.ignoresSafeArea()

            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let playbackError {
                VStack(spacing: 16) {
                    Text("Playback Error")
                        .font(.title2)
                    Text(playbackError)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if let playback = currentPlayback {
                VStack(alignment: .leading, spacing: 6) {
                    Text(channel.name)
                        .font(.title3)
                        .bold()
                    Text("Now Playing: \(playback.media.title)")
                        .font(.footnote)
                    Text("Elapsed \(formattedTime(playback.offset)) of \(formattedTime(playback.media.duration))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding()
            }
        }
        .task {
            await tuneToCurrentProgram()
            startTimer()
        }
        .onDisappear {
            cleanup()
        }
    }

    @MainActor
    private func tuneToCurrentProgram() async {
        guard let position = channel.playbackPosition() else {
            playbackError = "No playable media available for this channel."
            return
        }

        await load(media: position.media, offset: position.offset, preferTranscode: false)
    }

    @MainActor
    private func load(media: Channel.Media, offset: TimeInterval, preferTranscode: Bool) async {
        guard let streamURL = plexService.streamURL(for: media, offset: offset, preferTranscode: preferTranscode) else {
            playbackError = "Unable to construct a Plex stream URL."
            return
        }

        let playerItem = AVPlayerItem(url: streamURL)
        currentPlayback = (media, offset)
        playbackError = nil

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        observePlaybackEnd(for: playerItem)
        observeStatus(for: playerItem, media: media, offset: offset, preferTranscode: preferTranscode)

        let targetTime = CMTime(seconds: offset, preferredTimescale: 600)
        player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player?.play()
        }
    }

    @MainActor
    private func observePlaybackEnd(for item: AVPlayerItem) {
        if let playbackObserver {
            NotificationCenter.default.removeObserver(playbackObserver)
        }

        playbackObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            Task {
                await tuneToCurrentProgram()
            }
        }
    }

    @MainActor
    private func observeStatus(for item: AVPlayerItem, media: Channel.Media, offset: TimeInterval, preferTranscode: Bool) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new, .initial]) { _, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .failed:
                    if !preferTranscode {
                        Task { await load(media: media, offset: offset, preferTranscode: true) }
                    } else {
                        playbackError = item.error?.localizedDescription ?? "Playback failed."
                    }
                default:
                    break
                }
            }
        }
    }

    @MainActor
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor in
                currentPlayback = channel.playbackState()
            }
        }
    }

    @MainActor
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func cleanup() {
        stopTimer()

        if let playbackObserver {
            NotificationCenter.default.removeObserver(playbackObserver)
            self.playbackObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil

        player?.pause()
        player = nil
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite && interval > 0 else { return "00:00" }
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
