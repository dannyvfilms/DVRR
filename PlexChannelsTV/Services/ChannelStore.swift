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
    private static let orderKey = "channels.order"

    @Published private(set) var channels: [Channel] = [] {
        didSet {
            persistChannels()
        }
    }
    
    private var channelOrder: [UUID] = [] {
        didSet {
            persistOrder()
        }
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let storageURL: URL
    private let orderURL: URL
    private var isRestoring = false

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = userDefaults
        self.fileManager = fileManager
        self.storageURL = ChannelStore.resolveStorageURL(using: fileManager)
        self.orderURL = storageURL.deletingLastPathComponent().appendingPathComponent("channel_order.json", isDirectory: false)
        AppLoggers.channel.info("event=channel.persist.path path=\(self.storageURL.path, privacy: .public)")

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
        
        // Load channel order
        if let order = loadChannelOrder() {
            self.channelOrder = order
            // Apply order if we have channels and order
            if !channels.isEmpty && !channelOrder.isEmpty {
                applyOrder()
            }
        } else if !channels.isEmpty {
            // Initialize order from current channel order
            channelOrder = channels.map { $0.id }
            persistOrder()
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
        if !channelOrder.contains(channel.id) {
            channelOrder.append(channel.id)
        }
        return true
    }
    
    func setChannelOrder(_ order: [UUID]) {
        channelOrder = order
        applyOrder()
    }
    
    private func applyOrder() {
        // Create a dictionary for fast lookup
        let channelDict = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        
        // Build ordered array, filtering out any missing channels
        var orderedChannels: [Channel] = []
        var seenIDs = Set<UUID>()
        
        // Add channels in the specified order
        for id in channelOrder {
            if let channel = channelDict[id], !seenIDs.contains(id) {
                orderedChannels.append(channel)
                seenIDs.insert(id)
            }
        }
        
        // Add any channels not in the order (newly added channels)
        for channel in channels where !seenIDs.contains(channel.id) {
            orderedChannels.append(channel)
            channelOrder.append(channel.id)
        }
        
        channels = orderedChannels
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
            let targetType: PlexMediaType = library.type == .show ? .episode : library.type
            let itemsResponse = try await plexService.fetchLibraryItems(
                for: library,
                mediaType: targetType
            )

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
                libraryType: targetType,
                scheduleAnchor: startAt,
                items: mediaItems,
                sourceLibraries: [Channel.SourceLibrary(
                    id: library.uuid,
                    key: library.key,
                    title: library.title,
                    type: targetType
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
        channelOrder.removeAll { $0 == channel.id }
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
    
    private func persistOrder() {
        guard !isRestoring else { return }
        
        do {
            let data = try JSONEncoder().encode(channelOrder)
            try ensureStorageDirectoryExists()
            try data.write(to: orderURL, options: .atomic)
        } catch {
            print("ChannelStore.persistOrder write error: \(error)")
        }
    }
    
    private func loadChannelOrder() -> [UUID]? {
        guard fileManager.fileExists(atPath: orderURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: orderURL)
            return try JSONDecoder().decode([UUID].self, from: data)
        } catch {
            print("ChannelStore.loadChannelOrder decode error: \(error)")
            return nil
        }
    }

    private func ensureStorageDirectoryExists() throws {
        let directory = storageURL.deletingLastPathComponent()
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
    }

    private static func resolveStorageURL(using fileManager: FileManager) -> URL {
        let baseURL: URL
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            baseURL = appSupport.appendingPathComponent("Channels", isDirectory: true)
        } else if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            baseURL = documents.appendingPathComponent("Channels", isDirectory: true)
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
