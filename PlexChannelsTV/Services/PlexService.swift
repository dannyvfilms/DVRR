//
//  PlexService.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/19/25.
//

import Foundation
import PlexKit

extension Notification.Name {
    static let plexSessionShouldRefresh = Notification.Name("PlexService.sessionShouldRefresh")
}

@MainActor
final class PlexService: ObservableObject {

    enum StreamKind: String {
        case direct = "direct"
        case hls = "hls"
    }

    struct StreamDescriptor {
        let url: URL
        let kind: StreamKind
        let offset: TimeInterval
    }

    enum TokenType: String {
        case server
        case account
    }

    struct StreamRequestOptions {
        var preferDirect: Bool = true
        var preferredMaxBitrate: Int = 8_000  // Reduced from 10Mbps for better stability
        var forceTranscode: Bool = false
        var forceRemux: Bool = false
        var forceNewSession: Bool = false  // Force new transcoder session (for recovery)
    }

    struct StreamPlan {
        let mode: StreamKind
        let url: URL
        let startAt: TimeInterval
        let reason: String
        let tokenType: TokenType
        let baseURL: URL
        let partID: Int?
        let request: StreamRequestOptions
        let directStream: Bool
        let directPlay: Bool
        let maxVideoBitrate: Int?
    }

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
        case invalidURL
        case networkError
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
            case .invalidURL:
                return "Invalid URL constructed for API request."
            case .networkError:
                return "Network error occurred while fetching data."
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
    private let productName: String
    private let clientVersion: String
    private let platformName: String
    private let deviceModel: String
    private let deviceDisplayName: String
    private let clientIdentifierValue: String
    private var lastRefreshRequest: Date?

    var clientIdentifier: String {
        clientIdentifierValue
    }

    init(
        credentialStore: PlexCredentialStore = PlexCredentialStore(),
        productName: String = "PlexChannelsTV",
        version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        platform: String = "tvOS",
        device: String = "Apple TV",
        deviceName: String = "Apple TV"
    ) {
        self.credentialStore = credentialStore
        self.productName = productName
        self.clientVersion = version
        self.platformName = platform
        self.deviceModel = device
        self.deviceDisplayName = deviceName

        let clientIdentifier: String = {
            if let stored = credentialStore.clientIdentifier {
                return stored
            }
            let generated = UUID().uuidString
            credentialStore.clientIdentifier = generated
            return generated
        }()
        self.clientIdentifierValue = clientIdentifier

        let configuration = URLSessionConfiguration.default
        let info = Plex.ClientInfo(
            clientIdentifier: clientIdentifier,
            product: productName,
            version: version,
            platform: platform,
            device: device,
            deviceName: deviceName
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
            logSessionInfo(newSession)
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
            if let session {
                logSessionInfo(session)
            }
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

    private func fetchLibraryItemsPage(
        libraryKey: String,
        mediaType: PlexMediaType,
        baseURL: URL,
        token: String,
        start: Int,
        size: Int
    ) async throws -> [PlexMediaItem] {
        let safeStart = max(0, start)
        let safeSize = max(1, size)
        let range = safeStart...(safeStart + safeSize - 1)
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
        do {
            guard let currentSession = session else {
                throw ServiceError.noActiveSession
            }
            let token = currentSession.server.accessToken

            if let limit, limit > 0 {
                return try await performWithServerFallback { baseURL in
                    try await self.fetchLibraryItemsPage(
                        libraryKey: library.key,
                        mediaType: mediaType,
                        baseURL: baseURL,
                        token: token,
                        start: 0,
                        size: limit
                    )
                }
            }

            var results: [PlexMediaItem] = []
            var start = 0
            var batchSize = 400
            let minimumBatchSize = 50

            AppLoggers.net.info("event=plexService.fetchLibraryItems.start libraryType=\(mediaType.rawValue) libraryKey=\(library.key, privacy: .public) limit=nil")

            while true {
                do {
                    let page = try await performWithServerFallback { baseURL in
                        try await self.fetchLibraryItemsPage(
                            libraryKey: library.key,
                            mediaType: mediaType,
                            baseURL: baseURL,
                            token: token,
                            start: start,
                            size: batchSize
                        )
                    }

                    AppLoggers.net.info("event=plexService.fetchLibraryItems.page libraryType=\(mediaType.rawValue) start=\(start) size=\(batchSize) pageCount=\(page.count) totalSoFar=\(results.count)")

                    if page.isEmpty {
                        AppLoggers.net.info("event=plexService.fetchLibraryItems.empty libraryType=\(mediaType.rawValue) breaking")
                        break
                    }

                    results.append(contentsOf: page)

                    if page.count < batchSize {
                        AppLoggers.net.info("event=plexService.fetchLibraryItems.complete libraryType=\(mediaType.rawValue) pageCount=\(page.count) batchSize=\(batchSize) totalItems=\(results.count)")
                        // For movies, continue fetching even if page is smaller than batch size
                        // This handles cases where Plex returns 399 items instead of 400
                        if mediaType == .movie && page.count > 0 {
                            AppLoggers.net.info("event=plexService.fetchLibraryItems.continue libraryType=movie pageCount=\(page.count) batchSize=\(batchSize)")
                            start += page.count
                            continue
                        }
                        break
                    }

                    start += page.count
                } catch {
                    if shouldReduceBatch(for: error), batchSize > minimumBatchSize {
                        batchSize = max(minimumBatchSize, batchSize / 2)
                        AppLoggers.net.warning(
                            "event=plex.fetch.batch.retry size=\(batchSize) reason=\(String(describing: error), privacy: .public)"
                        )
                        continue
                    }
                    throw error
                }
            }

            return results
        } catch {
            if let reason = refreshReason(for: error) {
                requestSessionRefresh(reason: reason)
            }
            throw error
        }
    }

    func fetchLibraryItems(
        for library: PlexLibrary,
        mediaType: PlexMediaType,
        limit: Int? = nil,
        customKey: String
    ) async throws -> [PlexMediaItem] {
        do {
            guard let currentSession = session else {
                throw ServiceError.noActiveSession
            }
            let token = currentSession.server.accessToken

            if let limit, limit > 0 {
                return try await performWithServerFallback { baseURL in
                    try await self.fetchLibraryItemsPage(
                        libraryKey: customKey,
                        mediaType: mediaType,
                        baseURL: baseURL,
                        token: token,
                        start: 0,
                        size: limit
                    )
                }
            }

            var results: [PlexMediaItem] = []
            var start = 0
            var batchSize = 400
            let minimumBatchSize = 50

            while true {
                do {
                    let page = try await performWithServerFallback { baseURL in
                        try await self.fetchLibraryItemsPage(
                            libraryKey: customKey,
                            mediaType: mediaType,
                            baseURL: baseURL,
                            token: token,
                            start: start,
                            size: batchSize
                        )
                    }

                    if page.isEmpty {
                        break
                    }

                    results.append(contentsOf: page)

                    if page.count < batchSize {
                        break
                    }

                    start += page.count
                } catch {
                    if shouldReduceBatch(for: error), batchSize > minimumBatchSize {
                        batchSize = max(minimumBatchSize, batchSize / 2)
                        AppLoggers.net.warning(
                            "event=plex.fetch.batch.retry size=\(batchSize) reason=\(String(describing: error), privacy: .public)"
                        )
                        continue
                    }
                    throw error
                }
            }

            return results
        } catch {
            if let reason = refreshReason(for: error) {
                requestSessionRefresh(reason: reason)
            }
            throw error
        }
    }

    func fetchShowEpisodes(
        showRatingKey: String,
        baseURL: URL,
        token: String
    ) async throws -> [PlexMediaItem] {
        // First, get all seasons for this show
        let seasonsURLString = "\(baseURL.absoluteString)/library/metadata/\(showRatingKey)/children"
        guard var seasonsComponents = URLComponents(string: seasonsURLString) else {
            throw ServiceError.invalidURL
        }
        
        seasonsComponents.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        
        guard let seasonsURL = seasonsComponents.url else {
            throw ServiceError.invalidURL
        }
        
        var seasonsRequest = URLRequest(url: seasonsURL)
        seasonsRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (seasonsData, seasonsResponse) = try await URLSession.shared.data(for: seasonsRequest)
        
        guard let seasonsHttpResponse = seasonsResponse as? HTTPURLResponse,
              seasonsHttpResponse.statusCode == 200 else {
            throw ServiceError.networkError
        }
        
        // Decode seasons
        struct Season: Decodable {
            let ratingKey: String
            let title: String
            
            enum CodingKeys: String, CodingKey {
                case ratingKey = "ratingKey"
                case title = "title"
            }
        }
        
        struct SeasonsContainer: Decodable {
            let Metadata: [Season]
        }
        
        struct SeasonsResponse: Decodable {
            let MediaContainer: SeasonsContainer
        }
        
        let seasonsDecoder = JSONDecoder()
        let seasonsDecodedResponse = try seasonsDecoder.decode(SeasonsResponse.self, from: seasonsData)
        let seasons = seasonsDecodedResponse.MediaContainer.Metadata
        
        // Now fetch episodes from each season
        var allEpisodes: [PlexMediaItem] = []
        
        for season in seasons {
            let episodesURLString = "\(baseURL.absoluteString)/library/metadata/\(season.ratingKey)/children"
            guard var episodesComponents = URLComponents(string: episodesURLString) else {
                continue
            }
            
            episodesComponents.queryItems = [
                URLQueryItem(name: "X-Plex-Token", value: token)
            ]
            
            guard let episodesURL = episodesComponents.url else {
                continue
            }
            
            var episodesRequest = URLRequest(url: episodesURL)
            episodesRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            
            do {
                let (episodesData, episodesResponse) = try await URLSession.shared.data(for: episodesRequest)
                
                guard let episodesHttpResponse = episodesResponse as? HTTPURLResponse,
                      episodesHttpResponse.statusCode == 200 else {
                    continue
                }
                
                // Decode episodes
                struct EpisodesContainer: Decodable {
                    let Metadata: [PlexMediaItem]
                }
                
                struct EpisodesResponse: Decodable {
                    let MediaContainer: EpisodesContainer
                }
                
                let episodesDecoder = JSONDecoder()
                let episodesDecodedResponse = try episodesDecoder.decode(EpisodesResponse.self, from: episodesData)
                allEpisodes.append(contentsOf: episodesDecodedResponse.MediaContainer.Metadata)
            } catch {
                // Skip this season if there's an error
                continue
            }
        }
        
        return allEpisodes
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
                logSessionInfo(newSession)
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

    private func refreshReason(for error: Error) -> String? {
        if let serviceError = error as? ServiceError {
            switch serviceError {
            case .noActiveSession:
                return "service.no_active_session"
            case .unknown(let underlying):
                return refreshReason(for: underlying)
            default:
                return nil
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "network.timeout"
            case .networkConnectionLost:
                return "network.connection_lost"
            case .notConnectedToInternet:
                return "network.offline"
            case .cannotConnectToHost:
                return "network.cannot_connect"
            case .cannotFindHost:
                return "network.cannot_find_host"
            case .dnsLookupFailed:
                return "network.dns_failed"
            default:
                return nil
            }
        }

        return nil
    }

    private func requestSessionRefresh(reason: String) {
        let now = Date()
        if let lastRefreshRequest, now.timeIntervalSince(lastRefreshRequest) < 15 {
            return
        }
        lastRefreshRequest = now
        AppLoggers.app.info("event=auth.refresh.request reason=\(reason, privacy: .public)")
        NotificationCenter.default.post(
            name: .plexSessionShouldRefresh,
            object: self,
            userInfo: ["reason": reason]
        )
    }

    private func shouldReduceBatch(for error: Error) -> Bool {
        if let serviceError = error as? ServiceError {
            switch serviceError {
            case .unknown(let underlying):
                return shouldReduceBatch(for: underlying)
            default:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut,
                 .networkConnectionLost,
                 .cannotConnectToHost,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        return false
    }

    func buildImageURL(from path: String, width: Int? = nil, height: Int? = nil) -> URL? {
        guard let session else { return nil }
        guard let baseURL = resolve(path: path, relativeTo: session.server.baseURL) else { return nil }

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

    func backgroundArtworkURL(for media: Channel.Media, width: Int = 1280, height: Int = 720, blur: Int = 32) -> URL? {
        guard let session else {
            AppLoggers.net.error("event=artwork.background itemID=\(media.id, privacy: .public) status=noSession")
            return nil
        }
        guard let path = media.backgroundArtworkCandidates.first else {
            AppLoggers.net.error("event=artwork.background itemID=\(media.id, privacy: .public) status=noCandidates candidates=\(media.backgroundArtworkCandidates, privacy: .public)")
            return nil
        }
        
        // Try transcoded URL first
        if let url = buildTranscodedArtworkURL(path: path, width: width, height: height, blur: blur, session: session) {
            return url
        }
        
        // Fallback to direct URL
        let directURL = buildImageURL(from: path, width: width, height: height)
        if directURL == nil {
            AppLoggers.net.error("event=artwork.background.failed itemID=\(media.id, privacy: .public) path=\(path, privacy: .public)")
        }
        return directURL
    }

    func posterArtworkURL(for media: Channel.Media, width: Int = 300, height: Int = 450) -> URL? {
        guard let session else {
            AppLoggers.net.error("event=artwork.poster itemID=\(media.id, privacy: .public) status=noSession")
            return nil
        }
        guard let path = media.posterArtworkCandidates.first else {
            AppLoggers.net.error("event=artwork.poster itemID=\(media.id, privacy: .public) status=noCandidates candidates=\(media.posterArtworkCandidates, privacy: .public)")
            return nil
        }
        
        // Try transcoded URL first
        if let url = buildTranscodedArtworkURL(path: path, width: width, height: height, blur: nil, session: session) {
            return url
        }
        
        // Fallback to direct URL
        let directURL = buildImageURL(from: path, width: width, height: height)
        if directURL == nil {
            AppLoggers.net.error("event=artwork.poster.failed itemID=\(media.id, privacy: .public) path=\(path, privacy: .public)")
        }
        return directURL
    }

    func logoArtworkURL(for media: Channel.Media, width: Int = 320, height: Int = 180) -> URL? {
        guard let session else {
            AppLoggers.net.error("event=artwork.logo itemID=\(media.id, privacy: .public) status=noSession")
            return nil
        }
        guard let path = media.logoArtworkCandidates.first else {
            // No candidates is normal for items without logos - don't log
            return nil
        }
        
        // Try transcoded URL first
        if let url = buildTranscodedArtworkURL(path: path, width: width, height: height, blur: nil, session: session) {
            return url
        }
        
        // Fallback to direct URL
        let directURL = buildImageURL(from: path, width: width, height: height)
        if directURL == nil {
            AppLoggers.net.error("event=artwork.logo.failed itemID=\(media.id, privacy: .public) path=\(path, privacy: .public)")
        }
        return directURL
    }

    private func buildTranscodedArtworkURL(
        path: String,
        width: Int,
        height: Int,
        blur: Int?,
        session: Session
    ) -> URL? {
        guard let target = resolve(path: path, relativeTo: session.server.baseURL) else { return nil }
        
        // For transcoded images, we need a properly formatted URL with the token in the target URL
        guard var targetComponents = URLComponents(url: target, resolvingAgainstBaseURL: true) else { return nil }
        var targetItems = targetComponents.queryItems ?? []
        targetItems.append(URLQueryItem(name: "X-Plex-Token", value: session.server.accessToken))
        targetComponents.queryItems = targetItems
        
        guard let targetURLWithToken = targetComponents.url else { return nil }
        
        guard let transcodeBase = URL(string: "photo/:/transcode", relativeTo: session.server.baseURL) else { return nil }
        guard var components = URLComponents(url: transcodeBase, resolvingAgainstBaseURL: true) else { return nil }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "X-Plex-Token", value: session.server.accessToken),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "upscale", value: "1"),
            URLQueryItem(name: "url", value: targetURLWithToken.absoluteString)
        ]

        if let blur {
            items.append(URLQueryItem(name: "blur", value: "\(blur)"))
        }

        components.queryItems = items
        return components.url
    }

    private func resolve(path: String, relativeTo base: URL) -> URL? {
        if let url = URL(string: path), url.scheme != nil {
            return url
        }

        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.appendingPathComponent(trimmed)
    }

    func streamURLForItem(
        itemID: String,
        startAtSec: TimeInterval,
        options: StreamRequestOptions = StreamRequestOptions()
    ) async throws -> StreamPlan {
        guard let currentSession = session else {
            throw ServiceError.noActiveSession
        }

        let offset = max(0, startAtSec)
        let urls = orderedUnique([currentSession.server.baseURL] + currentSession.server.fallbackURLs)
        let tokens = orderedTokens(for: currentSession)
        var lastError: Error?

        for (index, baseURL) in urls.enumerated() {
            if baseURL.scheme?.lowercased() != "https" {
                AppLoggers.net.warning(
                    "event=net.insecureURL url=\(baseURL.redactedForLogging(), privacy: .public)"
                )
            }

            for tokenCandidate in tokens {
                do {
                    let metadata = try await fetchMetadata(
                        for: itemID,
                        baseURL: baseURL,
                        token: tokenCandidate.token,
                        tokenType: tokenCandidate.type
                    )
                    let plan = try buildStreamPlan(
                        metadata: metadata,
                        baseURL: baseURL,
                        token: tokenCandidate.token,
                        tokenType: tokenCandidate.type,
                        offset: offset,
                        options: options
                    )

                    if index != 0 {
                        promoteActiveServer(to: baseURL, allURLs: urls, preservingLibraries: currentSession.libraries)
                    }

                    let remuxValue = plan.directStream ? 1 : 0
                    let bitrateValue = plan.maxVideoBitrate ?? 0
                    AppLoggers.playback.info(
                        "event=play.plan mode=\(plan.mode.rawValue, privacy: .public) remux=\(remuxValue) bitrateKbps=\(bitrateValue) url=\(plan.url.redactedForLogging(), privacy: .public) offsetSec=\(Int(plan.startAt)) reason=\(plan.reason, privacy: .public)"
                    )

                    return plan
                } catch StreamResolutionError.unauthorized(_) {
                    AppLoggers.net.error(
                        "event=net.requestUnauthorized url=\(baseURL.redactedForLogging(), privacy: .public) tokenType=\(tokenCandidate.type.rawValue, privacy: .public)"
                    )
                    AppLoggers.net.info(
                        "event=net.retry reason=auth currentTokenType=\(tokenCandidate.type.rawValue, privacy: .public)"
                    )
                    lastError = PlaybackError.noStreamURL
                    continue
                } catch {
                    lastError = error
                    AppLoggers.net.error(
                        "event=net.metadataFailure url=\(baseURL.redactedForLogging(), privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    continue
                }
            }
        }

        if let lastError {
            throw lastError
        }

        throw PlaybackError.noStreamURL
    }

    func streamDescriptor(
        for media: Channel.Media,
        offset: TimeInterval = 0,
        preferTranscode: Bool = false
    ) -> StreamDescriptor? {
        guard let currentSession = session else {
            AppLoggers.playback.error("event=play.legacyDescriptor status=error reason=\"no_active_session\"")
            return nil
        }

        if !preferTranscode,
           let directURL = directPlayURL(
               for: media,
               token: currentSession.server.accessToken,
               baseURL: currentSession.server.baseURL
           ) {
            AppLoggers.playback.info(
                "event=play.legacyDescriptor mode=direct itemID=\(media.id, privacy: .public)"
            )
            return StreamDescriptor(url: directURL, kind: .direct, offset: offset)
        }

        if !preferTranscode {
            AppLoggers.playback.info(
                "event=play.legacyDescriptor mode=hls reason=\"force_transcode\" itemID=\(media.id, privacy: .public)"
            )
        }

        guard let transcode = transcodeURL(
            ratingKey: media.id,
            offset: offset,
            token: currentSession.server.accessToken,
            baseURL: currentSession.server.baseURL,
            options: HLSRequestOptions(
                directStream: false,
                directPlay: false,
                maxVideoBitrate: 10_000,
                videoCodec: nil,
                audioCodec: nil,
                forceNewSession: false
            )
        ) else {
            AppLoggers.playback.error(
                "event=play.legacyDescriptor status=error reason=\"no_transcode_url\" itemID=\(media.id, privacy: .public)"
            )
            return nil
        }
        AppLoggers.playback.info(
            "event=play.legacyDescriptor mode=hls itemID=\(media.id, privacy: .public)"
        )
        return StreamDescriptor(url: transcode, kind: .hls, offset: offset)
    }

    func streamURL(
        for media: Channel.Media,
        offset: TimeInterval = 0,
        preferTranscode: Bool = false
    ) -> URL? {
        streamDescriptor(for: media, offset: offset, preferTranscode: preferTranscode)?.url
    }

    func quickPlayURL(for media: Channel.Media) async throws -> URL {
        if let direct = streamDescriptor(for: media, preferTranscode: false) {
            return direct.url
        }
        if let fallback = streamDescriptor(for: media, preferTranscode: true) {
            return fallback.url
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
                if let session {
                    logSessionInfo(session)
                }

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

    private func logSessionInfo(_ session: Session) {
        let serverURI = session.server.baseURL.redactedForLogging()
        let fallbackCount = session.server.fallbackURLs.count
        AppLoggers.app.info(
            "event=session serverURI=\(serverURI, privacy: .public) tokenKind=server fallbackCount=\(fallbackCount)"
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

    private func standardQueryItems(token: String) -> [URLQueryItem] {
        [
            .init(name: "X-Plex-Token", value: token),
            .init(name: "X-Plex-Client-Identifier", value: clientIdentifierValue),
            .init(name: "X-Plex-Product", value: productName),
            .init(name: "X-Plex-Version", value: clientVersion),
            .init(name: "X-Plex-Platform", value: platformName),
            .init(name: "X-Plex-Device", value: deviceModel),
            .init(name: "X-Plex-Device-Name", value: deviceDisplayName)
        ]
    }

    private func mergeStandardQueryItems(into items: [URLQueryItem], token: String) -> [URLQueryItem] {
        let existing = Set(items.map(\.name))
        let additional = standardQueryItems(token: token).filter { !existing.contains($0.name) }
        return items + additional
    }

    private func streamSessionIdentifier(for media: Channel.Media, forceNew: Bool = false) -> String {
        streamSessionIdentifier(forItemID: media.id, forceNew: forceNew)
    }

    private func streamSessionIdentifier(forItemID id: String, forceNew: Bool = false) -> String {
        if forceNew {
            // Append timestamp to force new transcoder session on recovery
            let timestamp = Int(Date().timeIntervalSince1970)
            return "channels-\(clientIdentifierValue)-\(id)-\(timestamp)"
        }
        return "channels-\(clientIdentifierValue)-\(id)"
    }

    private func directPlayURL(for media: Channel.Media, token: String, baseURL: URL) -> URL? {
        guard let partKey = media.partKey else {
            AppLoggers.playback.error(
                "event=play.planSkipping reason=\"missing_part_key\" itemID=\(media.id, privacy: .public)"
            )
            return nil
        }
        return directPlayURL(partKey: partKey, token: token, baseURL: baseURL)
    }

    private func directPlayURL(partKey: String, token: String, baseURL: URL) -> URL? {
        let url: URL
        if let resolved = URL(string: partKey, relativeTo: baseURL) {
            url = resolved
        } else {
            let trimmed = partKey.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url = baseURL.appendingPathComponent(trimmed)
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let items = mergeStandardQueryItems(into: components.queryItems ?? [], token: token)
        components.queryItems = items
        return components.url
    }

    private func transcodeURL(
        ratingKey: String,
        offset: TimeInterval,
        token: String,
        baseURL: URL,
        options: HLSRequestOptions
    ) -> URL? {
        let path = "/video/:/transcode/universal/start.m3u8"
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }

        var queryItems = standardQueryItems(token: token)
        let sessionID = streamSessionIdentifier(forItemID: ratingKey, forceNew: options.forceNewSession)
        queryItems.append(contentsOf: [
            .init(name: "path", value: "/library/metadata/\(ratingKey)"),
            .init(name: "offset", value: String(Int(offset))),
            .init(name: "protocol", value: "hls"),
            .init(name: "directPlay", value: options.directPlay ? "1" : "0"),
            .init(name: "directStream", value: options.directStream ? "1" : "0"),
            .init(name: "fastSeek", value: "1"),
            .init(name: "copyts", value: "1"),
            .init(name: "mediaIndex", value: "0"),
            .init(name: "partIndex", value: "0"),
            .init(name: "audioBoost", value: "100"),
            .init(name: "maxVideoBitrate", value: String(options.maxVideoBitrate)),
            .init(name: "subtitleSize", value: "100"),
            .init(name: "session", value: sessionID),
            .init(name: "X-Plex-Session-Identifier", value: sessionID)
        ])

        if let videoCodec = options.videoCodec {
            queryItems.append(.init(name: "videoCodec", value: videoCodec))
        }
        if let audioCodec = options.audioCodec {
            queryItems.append(.init(name: "audioCodec", value: audioCodec))
        }

        components.queryItems = queryItems
        return components.url
    }

    private func orderedTokens(for session: Session) -> [(token: String, type: TokenType)] {
        var ordered: [(String, TokenType)] = [(session.server.accessToken, .server)]
        if session.accountToken != session.server.accessToken {
            ordered.append((session.accountToken, .account))
        }
        return ordered
    }

    private func fetchMetadata(
        for itemID: String,
        baseURL: URL,
        token: String,
        tokenType: TokenType
    ) async throws -> MetadataResponse.Metadata {
        guard let url = metadataURL(for: itemID, baseURL: baseURL, token: token) else {
            throw StreamResolutionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "X-Plex-Accept")
        request.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(platformName, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(deviceDisplayName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(clientIdentifierValue, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let start = Date()
        let method = request.httpMethod ?? "GET"
        let headers = summarizeHeaders(request.allHTTPHeaderFields)
        AppLoggers.net.info(
            "event=net.request method=\(method, privacy: .public) url=\(url.redactedForLogging(), privacy: .public) headers=\(headers, privacy: .public) startMs=\(Int(start.timeIntervalSince1970 * 1000))"
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLoggers.net.error("event=net.responseMissing elapsedMs=\(elapsed)")
                throw StreamResolutionError.http(status: -1)
            }

            AppLoggers.net.info(
                "event=net.response status=\(httpResponse.statusCode) elapsedMs=\(elapsed) bodyBytes=\(data.count)"
            )

            if httpResponse.statusCode == 401 {
                throw StreamResolutionError.unauthorized(tokenType)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw StreamResolutionError.http(status: httpResponse.statusCode)
            }

            do {
                let decoder = JSONDecoder()
                let decoded = try decoder.decode(MetadataResponse.self, from: data)
                guard let metadata = decoded.mediaContainer.metadata.first else {
                    throw StreamResolutionError.missingMetadata
                }
                return metadata
            } catch {
                throw StreamResolutionError.decoding(error)
            }
        } catch let error as StreamResolutionError {
            throw error
        } catch {
            AppLoggers.net.error(
                "event=net.requestFailed url=\(url.redactedForLogging(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func metadataURL(for itemID: String, baseURL: URL, token: String) -> URL? {
        let trimmed = "library/metadata/\(itemID)"
        guard var components = URLComponents(url: baseURL.appendingPathComponent(trimmed), resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.queryItems = mergeStandardQueryItems(into: components.queryItems ?? [], token: token)
        return components.url
    }

    private func buildStreamPlan(
        metadata: MetadataResponse.Metadata,
        baseURL: URL,
        token: String,
        tokenType: TokenType,
        offset: TimeInterval,
        options: StreamRequestOptions
    ) throws -> StreamPlan {
        let sanitizedOffset = max(0, offset)
        guard let media = metadata.media.first else {
            throw StreamResolutionError.missingMediaParts
        }
        guard let part = media.parts.first, let partKey = part.key else {
            throw StreamResolutionError.missingMediaParts
        }

        let container = (part.container ?? media.container)?.lowercased() ?? ""
        let isMKV = container == "mkv"
        let decision = evaluateDirectSupport(for: media)
        let directURL = directPlayURL(partKey: partKey, token: token, baseURL: baseURL)

        let shouldAttemptDirect = options.preferDirect &&
            !options.forceTranscode &&
            !options.forceRemux &&
            !isMKV

        if shouldAttemptDirect, decision.supported, let directURL {
            var appliedOptions = options
            appliedOptions.forceRemux = false
            return StreamPlan(
                mode: .direct,
                url: directURL,
                startAt: sanitizedOffset,
                reason: "direct:\(decision.reason)",
                tokenType: tokenType,
                baseURL: baseURL,
                partID: part.id,
                request: appliedOptions,
                directStream: false,
                directPlay: true,
                maxVideoBitrate: nil
            )
        }

        let remux = (options.forceRemux || isMKV) && !options.forceTranscode
        let maxBitrate = max(1_000, options.preferredMaxBitrate)
        let hlsOptions = HLSRequestOptions(
            directStream: remux,
            directPlay: false,
            maxVideoBitrate: maxBitrate,
            videoCodec: remux ? "copy" : "h264",
            audioCodec: remux ? "copy" : "aac",
            forceNewSession: options.forceNewSession
        )

        let hlsURL = try buildHLSURL(
            ratingKey: metadata.ratingKey,
            offset: sanitizedOffset,
            token: token,
            baseURL: baseURL,
            options: hlsOptions
        )

        let fallbackReason: String
        if options.forceTranscode {
            fallbackReason = "forced_transcode"
        } else if remux {
            let detail = container.isEmpty ? "unknown" : container
            fallbackReason = "force_remux:container=\(detail)"
        } else if !options.preferDirect {
            fallbackReason = "prefer_transcode"
        } else if !decision.supported {
            fallbackReason = "unsupported_codec:\(decision.reason)"
        } else if directURL == nil {
            fallbackReason = "missing_direct_url"
        } else {
            fallbackReason = "forced_hls"
        }

        var appliedOptions = options
        appliedOptions.forceRemux = remux

        return StreamPlan(
            mode: .hls,
            url: hlsURL,
            startAt: sanitizedOffset,
            reason: fallbackReason,
            tokenType: tokenType,
            baseURL: baseURL,
            partID: part.id,
            request: appliedOptions,
            directStream: remux,
            directPlay: false,
            maxVideoBitrate: maxBitrate
        )
    }

    private func buildHLSURL(
        ratingKey: String,
        offset: TimeInterval,
        token: String,
        baseURL: URL,
        options: HLSRequestOptions
    ) throws -> URL {
        guard let url = transcodeURL(
            ratingKey: ratingKey,
            offset: offset,
            token: token,
            baseURL: baseURL,
            options: options
        ) else {
            throw StreamResolutionError.missingMediaParts
        }
        return url
    }

    private func evaluateDirectSupport(for media: MetadataResponse.Media) -> DirectDecision {
        let supportedVideo: Set<String> = ["h264", "hevc", "mpeg4"]
        let supportedAudio: Set<String> = ["aac", "ac3", "eac3", "mp3", "dts"]

        let videoCodec = media.videoCodec?.lowercased() ?? "unknown"
        let audioValues = media.audioCodec?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty } ?? []

        let videoOK = supportedVideo.contains(videoCodec)
        let audioOK = audioValues.contains { supportedAudio.contains($0) }

        if videoOK && audioOK {
            let audioName = audioValues.first ?? "unknown"
            return DirectDecision(supported: true, reason: "\(videoCodec)+\(audioName)")
        }

        if !videoOK {
            return DirectDecision(supported: false, reason: "video=\(videoCodec)")
        }

        if audioValues.isEmpty {
            return DirectDecision(supported: false, reason: "audio=unknown")
        }

        return DirectDecision(
            supported: false,
            reason: "audio=\(audioValues.joined(separator: "+"))"
        )
    }

    private func summarizeHeaders(_ headers: [String: String]?) -> String {
        guard let headers, !headers.isEmpty else { return "none" }
        return headers.keys.sorted().joined(separator: ",")
    }

    private struct DirectDecision {
        let supported: Bool
        let reason: String
    }

    private struct HLSRequestOptions {
        let directStream: Bool
        let directPlay: Bool
        let maxVideoBitrate: Int
        let videoCodec: String?
        let audioCodec: String?
        let forceNewSession: Bool
    }

    private enum StreamResolutionError: Error {
        case invalidURL
        case unauthorized(TokenType)
        case missingMetadata
        case missingMediaParts
        case decoding(Error)
        case http(status: Int)
    }

    private struct MetadataResponse: Decodable {
        let mediaContainer: MediaContainer

        enum CodingKeys: String, CodingKey {
            case mediaContainer = "MediaContainer"
        }

        struct MediaContainer: Decodable {
            let metadata: [Metadata]

            enum CodingKeys: String, CodingKey {
                case metadata = "Metadata"
            }
        }

        struct Metadata: Decodable {
            let ratingKey: String
            let title: String?
            let duration: Int?
            let media: [Media]

            enum CodingKeys: String, CodingKey {
                case ratingKey
                case title
                case duration
                case media = "Media"
            }
        }

        struct Media: Decodable {
            let id: Int?
            let videoCodec: String?
            let audioCodec: String?
            let container: String?
            let parts: [Part]
            let decision: String?

            enum CodingKeys: String, CodingKey {
                case id
                case videoCodec
                case audioCodec
                case container
                case parts = "Part"
                case decision
            }
        }

        struct Part: Decodable {
            let id: Int?
            let key: String?
            let duration: Int?
            let container: String?
            let decision: String?

            enum CodingKeys: String, CodingKey {
                case id
                case key
                case duration
                case container
                case decision
            }
        }
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
