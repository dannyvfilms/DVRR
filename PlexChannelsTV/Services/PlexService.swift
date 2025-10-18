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

    @Published private(set) var session: Session?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var lastError: ServiceError?

    private let client: Plex
    private let credentialStore: PlexCredentialStore

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

            guard let baseURL = makeURL(from: selection.connection) else {
                throw ServiceError.unableToCreateServerURL
            }

            let librariesResponse: Plex.Request.Libraries.Response = try await perform(
                Plex.Request.Libraries(),
                baseURL: baseURL,
                token: selection.serverToken
            )

            let libraries = librariesResponse.mediaContainer.directory

            let server = Session.Server(
                identifier: selection.resource.clientIdentifier,
                name: selection.resource.name,
                baseURL: baseURL,
                accessToken: selection.serverToken
            )

            let newSession = Session(
                accountToken: token,
                user: authResponse.user,
                server: server,
                libraries: libraries
            )

            credentialStore.storeSession(
                PlexCredentialStore.StoredSession(
                    accountToken: token,
                    serverAccessToken: selection.serverToken,
                    serverURL: baseURL,
                    serverName: selection.resource.name,
                    serverIdentifier: selection.resource.clientIdentifier
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

        do {
            let response: Plex.Request.Libraries.Response = try await perform(
                Plex.Request.Libraries(),
                baseURL: currentSession.server.baseURL,
                token: currentSession.server.accessToken
            )

            let updatedSession = Session(
                accountToken: currentSession.accountToken,
                user: currentSession.user,
                server: currentSession.server,
                libraries: response.mediaContainer.directory
            )

            session = updatedSession
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
        token: String
    ) async throws -> [PlexMediaItem] {
        let request = Plex.Request.LibraryItems(
            key: libraryKey,
            mediaType: mediaType
        )
        let response: Plex.Request.LibraryItems.Response = try await perform(
            request,
            baseURL: baseURL,
            token: token
        )
        return response.mediaContainer.metadata
    }

    func fetchLibraryItems(for library: PlexLibrary) async throws -> [PlexMediaItem] {
        guard let currentSession = session else {
            throw ServiceError.noActiveSession
        }

        return try await fetchLibraryItems(
            libraryKey: library.key,
            mediaType: library.type,
            baseURL: currentSession.server.baseURL,
            token: currentSession.server.accessToken
        )
    }

    func streamURL(for media: Channel.Media, offset: TimeInterval = 0) -> URL? {
        guard let currentSession = session else { return nil }

        if let directURL = directPlayURL(for: media, token: currentSession.server.accessToken, baseURL: currentSession.server.baseURL) {
            return directURL
        }

        return transcodeURL(
            for: media,
            offset: offset,
            token: currentSession.server.accessToken,
            baseURL: currentSession.server.baseURL
        )
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
        do {
            let response: Plex.Request.Libraries.Response = try await perform(
                Plex.Request.Libraries(),
                baseURL: stored.serverURL,
                token: stored.serverAccessToken
            )

            let server = Session.Server(
                identifier: stored.serverIdentifier,
                name: stored.serverName,
                baseURL: stored.serverURL,
                accessToken: stored.serverAccessToken
            )

            session = Session(
                accountToken: stored.accountToken,
                user: nil,
                server: server,
                libraries: response.mediaContainer.directory
            )
        } catch {
            print("PlexService.restorePersistedSession error: \(error)")
            credentialStore.storeSession(nil)
        }
    }

    private func selectBestServer(
        from resources: [PlexResource],
        fallbackToken: String
    ) -> (resource: PlexResource, connection: PlexConnection, serverToken: String)? {
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
            guard let connection = bestConnection(for: resource) else { continue }

            let serverToken = resource.accessToken ?? fallbackToken
            return (resource, connection, serverToken)
        }

        return nil
    }

    private func bestConnection(for resource: PlexResource) -> PlexConnection? {
        guard !resource.connections.isEmpty else { return nil }

        return resource.connections.sorted { lhs, rhs in
            score(for: lhs) > score(for: rhs)
        }.first
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

        guard let url = URL(string: partKey, relativeTo: baseURL) ??
            baseURL.appendingPathComponent(partKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            return nil
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

        var queryItems: [URLQueryItem] = [
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
