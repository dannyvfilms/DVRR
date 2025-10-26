//
//  LibraryMediaCacheStore.swift
//  PlexChannelsTV
//
//  Created by Codex on 12/03/25.
//

import Foundation
import PlexKit

/// Persists full-library media snapshots to disk so channel building can reuse the
/// previously fetched dataset without waiting on Plex API pagination.
actor LibraryMediaCacheStore {
    enum CacheError: Error {
        case directoryCreationFailed(URL)
    }

    struct CacheKey: Hashable, Codable {
        let libraryID: String
        let mediaType: PlexMediaType

        var fileNameComponent: String {
            "\(libraryID)_\(mediaType.rawValue)"
        }
    }

    struct Entry: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let fetchedAt: Date
        let itemCount: Int
        let key: CacheKey
        let items: [PlexMediaItem]
    }

    static let shared = LibraryMediaCacheStore()

    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var memoryCache: [CacheKey: Entry] = [:]

    init(fileManager: FileManager = .default) {
        let baseURL: URL = {
            if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                return url
            }
            return fileManager.temporaryDirectory
        }()

        let directory = baseURL.appendingPathComponent("LibraryCache", isDirectory: true)
        self.directoryURL = directory

        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .deferredToDate
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .deferredToDate

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                AppLoggers.cache.error("event=libraryCache.directory.createFailed path=\(directory.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    func entry(for key: CacheKey) -> Entry? {
        if let cached = memoryCache[key] {
            AppLoggers.cache.info("event=libraryCache.hit source=memory libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) count=\(cached.itemCount)")
            return cached
        }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLoggers.cache.info("event=libraryCache.miss libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) reason=missingFile")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let entry = try decoder.decode(Entry.self, from: data)
            memoryCache[key] = entry
            AppLoggers.cache.info("event=libraryCache.hit source=disk libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) count=\(entry.itemCount)")
            return entry
        } catch {
            AppLoggers.cache.error("event=libraryCache.loadFailed libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
    
    /// Returns the cached item count for a library without loading the full dataset
    func itemCount(for key: CacheKey) -> Int? {
        if let cached = memoryCache[key] {
            return cached.itemCount
        }

        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let entry = try decoder.decode(Entry.self, from: data)
            memoryCache[key] = entry
            return entry.itemCount
        } catch {
            AppLoggers.cache.error("event=libraryCache.countFailed libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func store(items: [PlexMediaItem], for key: CacheKey) -> Entry {
        let entry = Entry(
            schemaVersion: Entry.currentSchemaVersion,
            fetchedAt: Date(),
            itemCount: items.count,
            key: key,
            items: items
        )
        memoryCache[key] = entry

        do {
            let data = try encoder.encode(entry)
            try data.write(to: fileURL(for: key), options: [.atomic])
            AppLoggers.cache.info("event=libraryCache.store libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) count=\(items.count)")
        } catch {
            AppLoggers.cache.error("event=libraryCache.storeFailed libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        return entry
    }

    /// Incrementally updates the cache by merging new items with existing ones
    /// - Preserves existing items that are still found
    /// - Adds new items that weren't previously cached
    /// - Removes items that are no longer found in the new dataset
    @discardableResult
    func updateIncrementally(newItems: [PlexMediaItem], for key: CacheKey) -> Entry {
        // Get existing items from cache
        let existingItems = entry(for: key)?.items ?? []
        
        // Create sets for efficient lookup
        let existingKeys = Set(existingItems.map(\.ratingKey))
        let newKeys = Set(newItems.map(\.ratingKey))
        
        // Find items to keep (existing items that are still in the new dataset)
        let itemsToKeep = existingItems.filter { newKeys.contains($0.ratingKey) }
        
        // Find new items to add (items in new dataset that weren't in existing cache)
        let itemsToAdd = newItems.filter { !existingKeys.contains($0.ratingKey) }
        
        // Combine kept items with new items
        let mergedItems = itemsToKeep + itemsToAdd
        
        // Log the update details
        let removedCount = existingItems.count - itemsToKeep.count
        AppLoggers.cache.info("event=libraryCache.updateIncremental libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) existing=\(existingItems.count) kept=\(itemsToKeep.count) added=\(itemsToAdd.count) removed=\(removedCount) final=\(mergedItems.count)")
        
        // Store the merged result
        return store(items: mergedItems, for: key)
    }

    func removeEntry(for key: CacheKey) {
        memoryCache.removeValue(forKey: key)
        do {
            try FileManager.default.removeItem(at: fileURL(for: key))
            AppLoggers.cache.info("event=libraryCache.remove libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public)")
        } catch {
            AppLoggers.cache.error("event=libraryCache.removeFailed libraryID=\(key.libraryID, privacy: .public) mediaType=\(key.mediaType.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func fileURL(for key: CacheKey) -> URL {
        directoryURL.appendingPathComponent("\(key.fileNameComponent).json")
    }
}
