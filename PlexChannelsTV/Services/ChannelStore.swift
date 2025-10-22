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
    private let fileManager: FileManager
    private let storageURL: URL
    private var isRestoring = false

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = userDefaults
        self.fileManager = fileManager
        self.storageURL = ChannelStore.resolveStorageURL(using: fileManager)

        isRestoring = true

        var needsMigrationPersist = false

        if let fileChannels = ChannelStore.loadChannels(fromFile: storageURL, using: fileManager) {
            self.channels = fileChannels
        } else if let legacyChannels = ChannelStore.loadChannels(from: defaults) {
            self.channels = legacyChannels
            defaults.removeObject(forKey: Self.storageKey)
            needsMigrationPersist = true
        } else {
            self.channels = []
        }

        isRestoring = false

        if needsMigrationPersist {
            persistChannels()
        }
    }

    func containsChannel(for library: PlexLibrary) -> Bool {
        channels.contains { channel in
            if channel.libraryKey == library.key { return true }
            return channel.sourceLibraries.contains { source in
                source.id == library.uuid || source.key == library.key
            }
        }
    }

    func channel(for library: PlexLibrary) -> Channel? {
        channels.first { channel in
            if channel.libraryKey == library.key { return true }
            return channel.sourceLibraries.contains { source in
                source.id == library.uuid || source.key == library.key
            }
        }
    }

    @discardableResult
    func addChannel(_ channel: Channel) -> Bool {
        if channels.contains(where: { $0.name.caseInsensitiveCompare(channel.name) == .orderedSame }) {
            return false
        }
        channels.append(channel)
        return true
    }

    func createChannel(
        named customName: String? = nil,
        from library: PlexLibrary,
        shuffle: Bool = false,
        startAt: Date = Date(),
        using plexService: PlexService
    ) async throws -> Channel {
        guard !containsChannel(for: library) else {
            throw ChannelCreationError.duplicate
        }

        do {
            let itemsResponse = try await plexService.fetchLibraryItems(for: library)

            var mediaItems = itemsResponse.compactMap(Channel.Media.from)

            guard !mediaItems.isEmpty else {
                throw ChannelCreationError.noPlayableItems
            }

            if shuffle {
                mediaItems.shuffle()
            }

            let channel = Channel(
                name: customName ?? library.title ?? "Channel",
                libraryKey: library.key,
                libraryType: library.type,
                scheduleAnchor: startAt,
                items: mediaItems,
                sourceLibraries: [Channel.SourceLibrary(
                    id: library.uuid,
                    key: library.key,
                    title: library.title,
                    type: library.type
                )],
                options: Channel.Options(shuffle: shuffle)
            )

            guard addChannel(channel) else {
                throw ChannelCreationError.duplicate
            }
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
        guard !isRestoring else { return }

        do {
            let data = try JSONEncoder().encode(channels)
            try ensureStorageDirectoryExists()
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("ChannelStore.persistChannels write error: \(error)")
        }
    }

    private func ensureStorageDirectoryExists() throws {
        let directory = storageURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    private static func resolveStorageURL(using fileManager: FileManager) -> URL {
        let baseURL: URL
        if let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            baseURL = appSupport
        } else if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            baseURL = documents
        } else {
            baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        }
        return baseURL.appendingPathComponent("channels.json", isDirectory: false)
    }

    private static func loadChannels(from defaults: UserDefaults) -> [Channel]? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        do {
            return try JSONDecoder().decode([Channel].self, from: data)
        } catch {
            print("ChannelStore.loadChannels decode error: \(error)")
            return nil
        }
    }

    private static func loadChannels(fromFile url: URL, using fileManager: FileManager) -> [Channel]? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Channel].self, from: data)
        } catch {
            print("ChannelStore.loadChannels file decode error: \(error)")
            return nil
        }
    }
}
