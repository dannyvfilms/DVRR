//
//  PlexHeaders.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation

enum PlexHeaders {
    static func make(
        clientID: String,
        product: String,
        version: String,
        device: String,
        platform: String,
        deviceName: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "X-Plex-Client-Identifier": clientID,
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Device": device,
            "X-Plex-Platform": platform,
        ]

        if let deviceName {
            headers["X-Plex-Device-Name"] = deviceName
        }

        headers["Accept"] = "application/json"
        return headers
    }
}
