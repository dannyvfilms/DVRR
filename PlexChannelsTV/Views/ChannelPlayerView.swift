//
//  ChannelPlayerView.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import SwiftUI
import Foundation

struct ChannelPlayerView: View {
    let channel: Channel

    @State private var currentPlayback = channel.playbackState()
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 24) {
            Text(channel.name)
                .font(.largeTitle)

            if let playback = currentPlayback {
                VStack(spacing: 12) {
                    Text(playback.media.title)
                        .font(.title2)
                    Text("Elapsed \(formattedTime(playback.offset)) of \(formattedTime(playback.media.duration))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Channel is ready to play.")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.top, 80)
        .onAppear(perform: startTimer)
        .onDisappear(perform: stopTimer)
    }

    private func startTimer() {
        stopTimer()
        currentPlayback = channel.playbackState()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            currentPlayback = channel.playbackState()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite && interval > 0 else { return "00:00:00" }
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
