//
//  PlexService.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import Foundation
import PlexKit

@MainActor
final class PlexService: ObservableObject {

    struct Session {
        struct Server {
            let identifier: String
            let name: String
            let baseURL: URL
            let accessToken: String
            let fallbackURLs: [URL]
        }

        let accountToken: String
        let user: PlexUser?
        let server: Server
        let libraries: [PlexLibrary]
    }

    enum ServiceError: LocalizedError {
        case missingAuthenticationToken
        case noActiveSession
        case unableToLocateServer
        case unableToCreateServerURL
        case failedToLoadLibraries
        case plex(PlexError)
        case unknown(Error)

        var errorDescription: String? {
            switch self {
            case .missingAuthenticationToken:
                return "Unable to retrieve authentication token from Plex."
            case .noActiveSession:
                return "No active Plex session is available."
            case .unableToLocateServer:
                return "No accessible Plex servers were found for this account."
            case .unableToCreateServerURL:
                return "The selected Plex server did not provide a usable connection URL."
            case .failedToLoadLibraries:
                return "Failed to fetch libraries from the selected Plex server."
            case .plex(let error):
                return "Plex API error: \(error.localizedDescription)"
            case .unknown(let error):
                return "Unexpected Plex error: \(error.localizedDescription)"
            }
        }
    }

    enum PlaybackError: LocalizedError {
        case noStreamURL

        var errorDescription: String? {
            switch self {
            case .noStreamURL:
                return "Unable to construct a stream URL for this media."
            }
        }
    }

    @Published private(set) var session: Session?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: ServiceError?

    private let client: Plex
    private let credentialStore: PlexCredentialStore

    var clientIdentifier: String {
        credentialStore.clientIdentifier ?? ""
    }

    init(
        credentialStore: PlexCredentialStore = PlexCredentialStore(),
        productName: String = "PlexChannelsTV",
        version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        platform: String = "tvOS",
        device: String = "Apple TV"
    ) {
        self.credentialStore = credentialStore

        let clientIdentifier: String = {
            if let stored = credentialStore.clientIdentifier {
                return stored
            }
            let generated = UUID().uuidString
            credentialStore.clientIdentifier = generated
            return generated
        }()

        let configuration = URLSessionConfiguration.default
        let info = Plex.ClientInfo(
            clientIdentifier: clientIdentifier,
            product: productName,
            version: version,
            platform: platform,
            device: device,
            deviceName: device
        )
        self.client = Plex(sessionConfiguration: configuration, clientInfo: info)

        restorePersistedSessionIfPossible()
    }

    func authenticate(username: String, password: String) async throws {
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        do {
            let authResponse: Plex.ServiceRequest.SimpleAuthentication.Response = try await perform(
                Plex.ServiceRequest.SimpleAuthentication(username: username, password: password)
            )

            guard let token = authResponse.user.authenticationToken ?? authResponse.user.authToken else {
                throw ServiceError.missingAuthenticationToken
            }

            let resources: [PlexResource] = try await perform(
                Plex.ServiceRequest.Resources(),
                token: token
            )

            guard let selection = selectBestServer(from: resources, fallbackToken: token) else {
                throw ServiceError.unableToLocateServer
            }

            let resolution = try await resolveConnections(
                selection.connections,
                token: selection.serverToken
            )

            let server = Session.Server(
                identifier: selection.resource.clientIdentifier,
                name: selection.resource.name,
                baseURL: resolution.baseURL,
                accessToken: selection.serverToken,
                fallbackURLs: resolution.fallbackURLs
            )

            let newSession = Session(
                accountToken: token,
                user: authResponse.user,
                server: server,
                libraries: resolution.libraries
            )

            credentialStore.storeSession(
                PlexCredentialStore.StoredSession(
                    accountToken: token,
                    serverAccessToken: selection.serverToken,
                    serverURL: resolution.baseURL,
                    serverName: selection.resource.name,
                    serverIdentifier: selection.resource.clientIdentifier,
                    fallbackServerURLs: resolution.fallbackURLs
                )
            )

            session = newSession
        } catch let error as ServiceError {
            lastError = error
            print("PlexService.authenticate error: \(error.localizedDescription)")
            throw error
        } catch let error as PlexError {
            let serviceError = ServiceError.plex(error)
            lastError = serviceError
            print("PlexService.authenticate plex error: \(error)")
            throw serviceError
        } catch {
            let serviceError = ServiceError.unknown(error)
            lastError = serviceError
            print("PlexService.authenticate unknown error: \(error)")
            throw serviceError
        }
    }

    func refreshLibraries() async throws {
        guard let currentSession = session else { return }

        let token = currentSession.server.accessToken

        do {
            let response: Plex.Request.Libraries.Response = try await performWithServerFallback { baseURL in
                try await self.perform(
                    Plex.Request.Libraries(),
                    baseURL: baseURL,
                    token: token
                )
            }

            guard let activeSession = session else { return }
            session = Session(
                accountToken: activeSession.accountToken,
                user: activeSession.user,
                server: activeSession.server,
                libraries: response.mediaContainer.directory
            )
        } catch let error as ServiceError {
            lastError = error
            print("PlexService.refreshLibraries error: \(error.localizedDescription)")
            throw error
        } catch let error as PlexError {
            let serviceError = ServiceError.plex(error)
            lastError = serviceError
            print("PlexService.refreshLibraries plex error: \(error)")
            throw serviceError
        } catch {
            let serviceError = ServiceError.unknown(error)
            lastError = serviceError
            print("PlexService.refreshLibraries unknown error: \(error)")
            throw serviceError
        }
    }

    func fetchLibraryItems(
        libraryKey: String,
        mediaType: PlexMediaType,
        baseURL: URL,
        token: String,
        limit: Int? = nil
    ) async throws -> [PlexMediaItem] {
        let range: CountableClosedRange<Int>? = {
            guard let limit, limit > 0 else { return nil }
            return 0...(limit - 1)
        }()

        let request = Plex.Request.LibraryItems(
            key: libraryKey,
            mediaType: mediaType,
            range: range
        )
        let response: Plex.Request.LibraryItems.Response = try await perform(
            request,
            baseURL: baseURL,
            token: token
        )
        return response.mediaContainer.metadata
    }

    func fetchLibraryItems(for library: PlexLibrary, limit: Int? = nil) async throws -> [PlexMediaItem] {
        try await fetchLibraryItems(for: library, mediaType: library.type, limit: limit)
    }

    func fetchLibraryItems(
        for library: PlexLibrary,
        mediaType: PlexMediaType,
        limit: Int? = nil
    ) async throws -> [PlexMediaItem] {
        guard let currentSession = session else {
            throw ServiceError.noActiveSession
        }
        let token = currentSession.server.accessToken

        return try await performWithServerFallback { baseURL in
            try await self.fetchLibraryItems(
                libraryKey: library.key,
                mediaType: mediaType,
                baseURL: baseURL,
                token: token,
                limit: limit
            )
        }
    }

    func establishSession(
        accountToken: String,
        serverName: String,
        serverIdentifier: String,
        serverURL: URL,
        fallbackServerURLs: [URL] = [],
        serverAccessToken: String
    ) async throws {
        let urls = orderedUnique([serverURL] + fallbackServerURLs)
        var lastError: Error?

        for (index, url) in urls.enumerated() {
            do {
                let response: Plex.Request.Libraries.Response = try await perform(
                    Plex.Request.Libraries(),
                    baseURL: url,
                    token: serverAccessToken
                )

                let fallback = orderedUnique(urls.enumerated().compactMap { idx, candidate in
                    idx == index ? nil : candidate
                })

                let server = Session.Server(
                    identifier: serverIdentifier,
                    name: serverName,
                    baseURL: url,
                    accessToken: serverAccessToken,
                    fallbackURLs: fallback
                )

                let newSession = Session(
                    accountToken: accountToken,
                    user: nil,
                    server: server,
                    libraries: response.mediaContainer.directory
                )

                let stored = PlexCredentialStore.StoredSession(
                    accountToken: accountToken,
                    serverAccessToken: serverAccessToken,
                    serverURL: url,
                    serverName: serverName,
                    serverIdentifier: serverIdentifier,
                    fallbackServerURLs: fallback
                )
                credentialStore.storeSession(stored)
                self.session = newSession
                return
            } catch {
                lastError = error
                print("[PlexService] establishSession connection \(url.absoluteString) failed: \(error)")
                continue
            }
        }

        if let serviceError = lastError as? ServiceError {
            throw serviceError
        }
        if let lastError {
            throw ServiceError.unknown(lastError)
        }
        throw ServiceError.failedToLoadLibraries
    }

    func buildImageURL(from path: String, width: Int? = nil, height: Int? = nil) -> URL? {
        guard let session else { return nil }
        let baseURL: URL
        if let resolved = URL(string: path, relativeTo: session.server.baseURL) {
            baseURL = resolved
        } else {
            baseURL = session.server.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else { return nil }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "X-Plex-Token", value: session.server.accessToken))
        if let width {
            items.append(URLQueryItem(name: "width", value: "\(width)"))
        }
        if let height {
            items.append(URLQueryItem(name: "height", value: "\(height)"))
        }
        components.queryItems = items
        return components.url
    }

    func streamURL(
        for media: Channel.Media,
        offset: TimeInterval = 0,
        preferTranscode: Bool = false
    ) -> URL? {
        guard let currentSession = session else { return nil }

        if !preferTranscode,
           let directURL = directPlayURL(
               for: media,
               token: currentSession.server.accessToken,
               baseURL: currentSession.server.baseURL
           ) {
            return directURL
        }

        return transcodeURL(
            for: media,
            offset: offset,
            token: currentSession.server.accessToken,
            baseURL: currentSession.server.baseURL
        )
    }

    func quickPlayURL(for media: Channel.Media) async throws -> URL {
        if let direct = streamURL(for: media, preferTranscode: false) {
            return direct
        }
        if let fallback = streamURL(for: media, preferTranscode: true) {
            return fallback
        }
        throw PlaybackError.noStreamURL
    }

    func signOut() {
        credentialStore.storeSession(nil)
        session = nil
        lastError = nil
    }

    private func restorePersistedSessionIfPossible() {
        guard let stored = credentialStore.loadSession() else { return }

        Task { [weak self] in
            await self?.restorePersistedSession(using: stored)
        }
    }

    private func restorePersistedSession(using stored: PlexCredentialStore.StoredSession) async {
        let urls = orderedUnique([stored.serverURL] + (stored.fallbackServerURLs ?? []))
        var lastError: Error?

        for (index, url) in urls.enumerated() {
            do {
                let response: Plex.Request.Libraries.Response = try await perform(
                    Plex.Request.Libraries(),
                    baseURL: url,
                    token: stored.serverAccessToken
                )

                let fallback = orderedUnique(urls.enumerated().compactMap { idx, candidate in
                    idx == index ? nil : candidate
                })

                let server = Session.Server(
                    identifier: stored.serverIdentifier,
                    name: stored.serverName,
                    baseURL: url,
                    accessToken: stored.serverAccessToken,
                    fallbackURLs: fallback
                )

                session = Session(
                    accountToken: stored.accountToken,
                    user: nil,
                    server: server,
                    libraries: response.mediaContainer.directory
                )

                credentialStore.storeSession(
                    PlexCredentialStore.StoredSession(
                        accountToken: stored.accountToken,
                        serverAccessToken: stored.serverAccessToken,
                        serverURL: url,
                        serverName: stored.serverName,
                        serverIdentifier: stored.serverIdentifier,
                        fallbackServerURLs: fallback
                    )
                )
                return
            } catch {
                lastError = error
                print("PlexService.restorePersistedSession connection \(url.absoluteString) failed: \(error)")
                continue
            }
        }
        let message = lastError?.localizedDescription ?? "Unknown"
        print("PlexService.restorePersistedSession error: \(message)")
        credentialStore.storeSession(nil)
    }

    private func selectBestServer(
        from resources: [PlexResource],
        fallbackToken: String
    ) -> (resource: PlexResource, connections: [PlexConnection], serverToken: String)? {
        let servers = resources.filter { $0.capabilities.contains(.server) }
            .sorted { lhs, rhs in
                let lhsOwned = lhs.owned ?? false
                let rhsOwned = rhs.owned ?? false
                if lhsOwned != rhsOwned { return lhsOwned }
                let lhsDate = lhs.lastSeenAt ?? .distantPast
                let rhsDate = rhs.lastSeenAt ?? .distantPast
                return lhsDate > rhsDate
            }

        for resource in servers {
            let connections = sortedConnections(for: resource)
            guard !connections.isEmpty else { continue }

            let serverToken = resource.accessToken ?? fallbackToken
            return (resource, connections, serverToken)
        }

        return nil
    }

    private func sortedConnections(for resource: PlexResource) -> [PlexConnection] {
        guard !resource.connections.isEmpty else { return [] }
        return resource.connections.sorted { lhs, rhs in
            score(for: lhs) > score(for: rhs)
        }
    }

    private func score(for connection: PlexConnection) -> Int {
        var score = 0
        if connection.local == true { score += 4 }
        if connection.relay == false { score += 2 }
        if connection.`protocol` == .https { score += 1 }
        return score
    }

    private func makeURL(from connection: PlexConnection) -> URL? {
        guard let directURL = URL(string: connection.uri) else {
            guard let scheme = connection.`protocol`?.rawValue else { return nil }
            var components = URLComponents()
            components.scheme = scheme
            components.host = connection.address
            components.port = connection.port
            return components.url
        }
        return directURL
    }

    private func resolveConnections(
        _ connections: [PlexConnection],
        token: String
    ) async throws -> (baseURL: URL, fallbackURLs: [URL], libraries: [PlexLibrary]) {
        var lastError: Error?
        for (index, connection) in connections.enumerated() {
            guard let url = makeURL(from: connection) else { continue }
            do {
                let response: Plex.Request.Libraries.Response = try await perform(
                    Plex.Request.Libraries(),
                    baseURL: url,
                    token: token
                )
                let libraries = response.mediaContainer.directory
                let fallback = orderedUnique(
                    connections.enumerated().compactMap { idx, element in
                        guard idx != index, let candidateURL = makeURL(from: element) else { return nil }
                        return candidateURL
                    }
                )
                return (url, fallback, libraries)
            } catch {
                lastError = error
                print("[PlexService] Connection \(url.absoluteString) failed with error: \(error)")
                continue
            }
        }

        if let serviceError = lastError as? ServiceError {
            throw serviceError
        }
        if let lastError {
            throw ServiceError.unknown(lastError)
        }
        throw ServiceError.unableToCreateServerURL
    }

    private func orderedUnique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for url in urls {
            if seen.insert(url).inserted {
                result.append(url)
            }
        }
        return result
    }

    private func performWithServerFallback<T>(
        operation: @escaping (_ baseURL: URL) async throws -> T
    ) async throws -> T {
        guard let currentSession = session else {
            throw ServiceError.noActiveSession
        }

        let urls = [currentSession.server.baseURL] + currentSession.server.fallbackURLs
        var lastError: Error?

        for (index, url) in urls.enumerated() {
            do {
                let result = try await operation(url)
                if index != 0 {
                    promoteActiveServer(to: url, allURLs: urls, preservingLibraries: currentSession.libraries)
                }
                return result
            } catch {
                lastError = error
                continue
            }
        }

        if let serviceError = lastError as? ServiceError {
            throw serviceError
        }
        if let lastError {
            throw ServiceError.unknown(lastError)
        }
        throw ServiceError.failedToLoadLibraries
    }

    private func promoteActiveServer(
        to activeURL: URL,
        allURLs: [URL],
        preservingLibraries libraries: [PlexLibrary]
    ) {
        guard let currentSession = session else { return }
        let fallback = orderedUnique(allURLs.filter { $0 != activeURL })
        let updatedServer = Session.Server(
            identifier: currentSession.server.identifier,
            name: currentSession.server.name,
            baseURL: activeURL,
            accessToken: currentSession.server.accessToken,
            fallbackURLs: fallback
        )
        let updatedSession = Session(
            accountToken: currentSession.accountToken,
            user: currentSession.user,
            server: updatedServer,
            libraries: libraries
        )
        session = updatedSession
        credentialStore.storeSession(
            PlexCredentialStore.StoredSession(
                accountToken: updatedSession.accountToken,
                serverAccessToken: updatedSession.server.accessToken,
                serverURL: activeURL,
                serverName: updatedSession.server.name,
                serverIdentifier: updatedSession.server.identifier,
                fallbackServerURLs: fallback
            )
        )
    }

    private func perform<Request: PlexServiceRequest>(
        _ request: Request,
        token: String? = nil
    ) async throws -> Request.Response {
        try await withCheckedThrowingContinuation { continuation in
            _ = client.request(request, token: token) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func perform<Request: PlexResourceRequest>(
        _ request: Request,
        baseURL: URL,
        token: String? = nil
    ) async throws -> Request.Response {
        try await withCheckedThrowingContinuation { continuation in
            _ = client.request(request, from: baseURL, token: token) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func directPlayURL(for media: Channel.Media, token: String, baseURL: URL) -> URL? {
        guard let partKey = media.partKey else { return nil }

        let url: URL
        if let resolved = URL(string: partKey, relativeTo: baseURL) {
            url = resolved
        } else {
            let trimmed = partKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url = baseURL.appendingPathComponent(trimmed)
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var items = components.queryItems ?? []
        items.append(.init(name: "X-Plex-Token", value: token))
        components.queryItems = items
        return components.url
    }

    private func transcodeURL(
        for media: Channel.Media,
        offset: TimeInterval,
        token: String,
        baseURL: URL
    ) -> URL? {
        let path = "/video/:/transcode/universal/start.m3u8"
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }

        let queryItems: [URLQueryItem] = [
            .init(name: "X-Plex-Token", value: token),
            .init(name: "path", value: "/library/metadata/\(media.id)"),
            .init(name: "offset", value: String(Int(offset))),
            .init(name: "protocol", value: "hls"),
            .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "1"),
            .init(name: "fastSeek", value: "1"),
        ]

        components.queryItems = queryItems
        return components.url
    }
}

// MARK: - Credential Store

final class PlexCredentialStore {
    struct StoredSession: Codable {
        let accountToken: String
        let serverAccessToken: String
        let serverURL: URL
        let serverName: String
        let serverIdentifier: String
        let fallbackServerURLs: [URL]?
    }

    private enum Keys {
        static let clientIdentifier = "plex.service.clientIdentifier"
        static let session = "plex.service.session"
    }

    private let defaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    var clientIdentifier: String? {
        get { defaults.string(forKey: Keys.clientIdentifier) }
        set { defaults.set(newValue, forKey: Keys.clientIdentifier) }
    }

    func storeSession(_ session: StoredSession?) {
        guard let session else {
            defaults.removeObject(forKey: Keys.session)
            return
        }

        do {
            let data = try JSONEncoder().encode(session)
            defaults.set(data, forKey: Keys.session)
        } catch {
            print("PlexCredentialStore.storeSession encoding error: \(error)")
        }
    }

    func loadSession() -> StoredSession? {
        guard let data = defaults.data(forKey: Keys.session) else { return nil }
        do {
            return try JSONDecoder().decode(StoredSession.self, from: data)
        } catch {
            print("PlexCredentialStore.loadSession decoding error: \(error)")
            defaults.removeObject(forKey: Keys.session)
            return nil
        }
    }
}
