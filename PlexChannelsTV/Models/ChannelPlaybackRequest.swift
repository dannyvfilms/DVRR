//
//  ChannelPlaybackRequest.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/25/25.
//

import Foundation
import PlexKit

struct ChannelPlaybackRequest: Identifiable, Equatable {
    let id = UUID()
    let channel: Channel
    let itemIndex: Int
    let item: Channel.Media
    let offset: TimeInterval
    let requestedAt: Date

    var channelID: Channel.ID { channel.id }
    var channelName: String { channel.name }
    var itemID: String { item.id }
    var itemTitle: String { item.metadata?.title ?? item.title }
    var itemKind: PlexMediaType? { item.metadata?.type }

    static func == (lhs: ChannelPlaybackRequest, rhs: ChannelPlaybackRequest) -> Bool {
        lhs.id == rhs.id
    }
}
