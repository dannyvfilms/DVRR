//
//  ChannelsCoordinator.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/25/25.
//

import Foundation

final class ChannelsCoordinator: ObservableObject {
    enum PresentationSource: String {
        case tap
        case beginning
        case upnext
        case force
    }

    @Published var playbackRequest: ChannelPlaybackRequest?

    private var watchdog: DispatchWorkItem?

    func presentNow(
        channel: Channel,
        at timestamp: Date = Date(),
        source: PresentationSource = .tap
    ) -> ChannelPlaybackRequest? {
        guard let position = channel.playbackPosition(at: timestamp) else {
            AppLoggers.channel.error(
                "event=channel.tap status=error reason=\"no_schedule\" channelID=\(channel.id.uuidString, privacy: .public)"
            )
            return nil
        }

        let request = ChannelPlaybackRequest(
            channel: channel,
            itemIndex: position.index,
            item: position.media,
            offset: position.offset,
            requestedAt: timestamp
        )

        assign(request, source: source)
        return request
    }

    func presentItem(
        channel: Channel,
        itemID: String,
        offset: TimeInterval,
        source: PresentationSource,
        at timestamp: Date = Date()
    ) -> ChannelPlaybackRequest? {
        guard let index = channel.items.firstIndex(where: { $0.id == itemID }) else {
            AppLoggers.playback.error(
                "event=player.present status=error reason=\"missing_item\" channelID=\(channel.id.uuidString, privacy: .public) itemID=\(itemID, privacy: .public)"
            )
            return nil
        }

        let media = channel.items[index]
        let request = ChannelPlaybackRequest(
            channel: channel,
            itemIndex: index,
            item: media,
            offset: max(0, offset),
            requestedAt: timestamp
        )

        assign(request, source: source)
        return request
    }

    func presentForce(channel: Channel, at timestamp: Date = Date()) -> ChannelPlaybackRequest? {
        guard let position = channel.playbackPosition(at: timestamp) else {
            AppLoggers.channel.error(
                "event=debug.forcePlay status=error reason=\"no_schedule\" channelID=\(channel.id.uuidString, privacy: .public)"
            )
            return nil
        }

        let request = ChannelPlaybackRequest(
            channel: channel,
            itemIndex: position.index,
            item: position.media,
            offset: position.offset,
            requestedAt: timestamp
        )

        AppLoggers.playback.info(
            "event=debug.forcePlay channelID=\(channel.id.uuidString, privacy: .public) itemID=\(position.media.id, privacy: .public) offsetSec=\(Int(position.offset))"
        )
        assign(request, source: .force)
        return request
    }

    func dismissPlayback() {
        playbackRequest = nil
        watchdog?.cancel()
        watchdog = nil
    }

    private func assign(_ request: ChannelPlaybackRequest, source: PresentationSource) {
        playbackRequest = request
        AppLoggers.playback.info(
            "event=player.present route=cover source=\(source.rawValue, privacy: .public) itemID=\(request.itemID, privacy: .public) offsetSec=\(Int(request.offset))"
        )
        scheduleWatchdog(for: request, source: source)
    }

    private func scheduleWatchdog(for request: ChannelPlaybackRequest, source: PresentationSource) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.playbackRequest == nil else { return }
            AppLoggers.playback.error(
                "event=player.present.missed channelID=\(request.channelID.uuidString, privacy: .public) channelName=\(request.channelName, privacy: .public) itemID=\(request.itemID, privacy: .public) source=\(source.rawValue, privacy: .public)"
            )
        }
        watchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: item)
    }
}
