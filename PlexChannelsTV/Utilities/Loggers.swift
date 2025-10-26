//
//  Loggers.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/25/25.
//

import Foundation
import os.log

enum AppLoggers {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "PlexChannelsTV"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let channel = Logger(subsystem: subsystem, category: "Channel")
    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let net = Logger(subsystem: subsystem, category: "Net")
    static let cache = Logger(subsystem: subsystem, category: "Cache")
}

extension URL {
    /// Returns a textual representation with sensitive query items (e.g. Plex tokens) redacted.
    func redactedForLogging() -> String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return absoluteString
        }

        if let items = components.queryItems, !items.isEmpty {
            components.queryItems = items.map { item in
                guard let value = item.value else { return item }
                if item.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame {
                    return URLQueryItem(name: item.name, value: "‹redacted›")
                }
                if value.count > 128 {
                    let truncated = String(value.prefix(125)) + "..."
                    return URLQueryItem(name: item.name, value: truncated)
                }
                return item
            }
        }

        return components.string ?? absoluteString
    }
}
