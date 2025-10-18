//
//  ChannelStore.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import Foundation
import PlexKit

@MainActor
final class ChannelStore: ObservableObject {
    enum ChannelCreationError: LocalizedError {
        case duplicate
        case noSession
        case noPlayableItems
        case plex(PlexError)
        case unknown(Error)

        var errorDescription: String? {
            switch self {
            case .duplicate:
                return "A channel for this library already exists."
            case .noSession:
                return "Please sign in to Plex before creating a channel."
            case .noPlayableItems:
                return "No playable media items were found in this library."
            case .plex(let error):
                return "Plex error: \(error.localizedDescription)"
            case .unknown(let error):
                return "Channel creation failed: \(error.localizedDescription)"
            }
        }
    }

    private static let storageKey = "channels.store"

    @Published private(set) var channels: [Channel] = [] {
        didSet {
            persistChannels()
        }
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
        self.channels = Self.loadChannels(from: defaults)
    }

    func containsChannel(for library: PlexLibrary) -> Bool {
        channels.contains { $0.libraryKey == library.key }
    }

    func createChannel(
        from library: PlexLibrary,
        using plexService: PlexService
    ) async throws -> Channel {
        guard !containsChannel(for: library) else {
            throw ChannelCreationError.duplicate
        }

        do {
            let itemsResponse = try await plexService.fetchLibraryItems(for: library)

            let mediaItems = itemsResponse.compactMap { item -> Channel.Media? in
                guard let duration = item.duration, duration > 0 else { return nil }
                return Channel.Media(
                    id: item.ratingKey,
                    title: item.title ?? "Untitled",
                    duration: TimeInterval(duration) / 1000.0
                )
            }

            guard !mediaItems.isEmpty else {
                throw ChannelCreationError.noPlayableItems
            }

            let channel = Channel(
                name: library.title ?? "Channel",
                libraryKey: library.key,
                libraryType: library.type,
                scheduleAnchor: Date(),
                items: mediaItems
            )

            channels.append(channel)
            return channel
        } catch let error as ChannelCreationError {
            throw error
        } catch let error as PlexService.ServiceError {
            switch error {
            case .noActiveSession:
                throw ChannelCreationError.noSession
            case .plex(let plexError):
                throw ChannelCreationError.plex(plexError)
            default:
                throw ChannelCreationError.unknown(error)
            }
        } catch let error as PlexError {
            throw ChannelCreationError.plex(error)
        } catch {
            throw ChannelCreationError.unknown(error)
        }
    }

    func removeChannel(_ channel: Channel) {
        channels.removeAll { $0.id == channel.id }
    }

    private func persistChannels() {
        do {
            let data = try JSONEncoder().encode(channels)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            print("ChannelStore.persistChannels encoding error: \(error)")
        }
    }

    private static func loadChannels(from defaults: UserDefaults) -> [Channel] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([Channel].self, from: data)
        } catch {
            print("ChannelStore.loadChannels decode error: \(error)")
            return []
        }
    }
}
