//
//  AuthState.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation
import Combine

struct PlexSessionInfo: Equatable {
    let authToken: String
    let serverURI: URL
    let serverAccessToken: String
    let serverName: String
    let libraryCount: Int
    let accountName: String
}

@MainActor
final class AuthState: ObservableObject {
    @Published var session: PlexSessionInfo?
    @Published var linkingError: String?
    @Published private(set) var isLinked = false

    private let plexService: PlexService
    private let linkService: PlexLinkService
    private let keychain: KeychainStorage
    private let keychainAccount = "plex.auth.token"
    private let channelSeeder: ChannelSeeder?

    private var cancellables: Set<AnyCancellable> = []
    private var isRefreshingSession = false

    init(
        plexService: PlexService,
        linkService: PlexLinkService,
        keychain: KeychainStorage = .shared,
        channelSeeder: ChannelSeeder? = nil
    ) {
        self.plexService = plexService
        self.linkService = linkService
        self.keychain = keychain
        self.channelSeeder = channelSeeder

        plexService.$session
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self = self else { return }
                self.handleSessionUpdate(session)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .plexSessionShouldRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let reason = notification.userInfo?["reason"] as? String ?? "unknown"
                Task { @MainActor in
                    await self.refreshSession(reason: reason)
                }
            }
            .store(in: &cancellables)

        Task {
            await bootstrapFromKeychain()
        }
    }

    func requestPin() async throws -> PinResponse {
        linkingError = nil
        return try await linkService.requestPin()
    }

    func prepareForLinking() {
        if plexService.session == nil {
            isLinked = false
            linkService.setLinked(false)
        }
    }

    func pollPin(id: Int, until deadline: Date) async throws -> String {
        if isLinked, session != nil {
            throw LinkError.alreadyLinked
        }
        return try await linkService.pollPin(id: id, until: deadline)
    }

    func completeLink(authToken: String) async throws {
        let devices = try await linkService.fetchResources(authToken: authToken)
        guard let chosen = linkService.chooseBestServer(devices) else {
            throw LinkError.invalidResponse
        }

        let account = try? await linkService.fetchAccount(authToken: authToken)
        let serverToken = chosen.accessToken.isEmpty ? authToken : chosen.accessToken

        let connectionURLs = chosen.connections.map { $0.uri }
        guard let primaryURL = connectionURLs.first else {
            throw LinkError.invalidResponse
        }

        try await plexService.establishSession(
            accountToken: authToken,
            serverName: chosen.device.name,
            serverIdentifier: chosen.device.clientIdentifier,
            serverURL: primaryURL,
            fallbackServerURLs: Array(connectionURLs.dropFirst()),
            serverAccessToken: serverToken
        )
        try keychain.store(token: authToken, account: keychainAccount)
        let activeURL = plexService.session?.server.baseURL ?? primaryURL

        if let seeder = channelSeeder, let libraries = plexService.session?.libraries {
            Task {
                await seeder.seedIfNeeded(libraries: libraries)
            }
        }

        let libraries = plexService.session?.libraries ?? []
        let info = PlexSessionInfo(
            authToken: authToken,
            serverURI: activeURL,
            serverAccessToken: serverToken,
            serverName: chosen.device.name,
            libraryCount: libraries.count,
            accountName: account?.title ?? account?.username ?? session?.accountName ?? "Plex User"
        )
        self.session = info
        isLinked = true
        linkService.setLinked(true)
    }

    func adoptCurrentSession() async {
        guard let session = plexService.session else { return }
        let info = PlexSessionInfo(
            authToken: session.accountToken,
            serverURI: session.server.baseURL,
            serverAccessToken: session.server.accessToken,
            serverName: session.server.name,
            libraryCount: session.libraries.count,
            accountName: session.user?.title ?? session.user?.username ?? self.session?.accountName ?? "Plex User"
        )
        self.session = info
        try? keychain.store(token: session.accountToken, account: keychainAccount)
        isLinked = true
        linkService.setLinked(true)
    }

    func refreshSession(reason: String = "manual") async {
        if isRefreshingSession { return }
        isRefreshingSession = true
        defer { isRefreshingSession = false }

        var candidateToken: String?
        if let current = session?.authToken {
            candidateToken = current
        } else {
            do {
                candidateToken = try keychain.readToken(account: keychainAccount)
            } catch {
                AppLoggers.app.error("event=auth.refresh.skip reason=keychain error=\(String(describing: error), privacy: .public)")
                linkingError = error.localizedDescription
                signOut()
                return
            }
        }

        guard let authToken = candidateToken else {
            AppLoggers.app.error("event=auth.refresh.skip reason=no_token")
            signOut()
            return
        }

        AppLoggers.app.info("event=auth.refresh.start reason=\(reason, privacy: .public)")

        do {
            let devices = try await linkService.fetchResources(authToken: authToken)
            guard let chosen = linkService.chooseBestServer(devices) else {
                throw LinkError.invalidResponse
            }

            let account = try? await linkService.fetchAccount(authToken: authToken)
            let serverToken = chosen.accessToken.isEmpty ? authToken : chosen.accessToken
            let connectionURLs = chosen.connections.map { $0.uri }
            guard let primaryURL = connectionURLs.first else {
                throw LinkError.invalidResponse
            }

            try await plexService.establishSession(
                accountToken: authToken,
                serverName: chosen.device.name,
                serverIdentifier: chosen.device.clientIdentifier,
                serverURL: primaryURL,
                fallbackServerURLs: Array(connectionURLs.dropFirst()),
                serverAccessToken: serverToken
            )

            try keychain.store(token: authToken, account: keychainAccount)

            let libraries = plexService.session?.libraries ?? []
            let activeURL = plexService.session?.server.baseURL ?? primaryURL
            let accountName = account?.title ?? account?.username ?? session?.accountName ?? "Plex User"

            session = PlexSessionInfo(
                authToken: authToken,
                serverURI: activeURL,
                serverAccessToken: serverToken,
                serverName: chosen.device.name,
                libraryCount: libraries.count,
                accountName: accountName
            )
            isLinked = true
            linkingError = nil
            linkService.setLinked(true)

            AppLoggers.app.info(
                "event=auth.refresh.ok serverURI=\(activeURL.redactedForLogging(), privacy: .public)"
            )

            if let seeder = channelSeeder {
                Task {
                    await seeder.seedIfNeeded(libraries: libraries)
                }
            }
        } catch {
            AppLoggers.app.error(
                "event=auth.refresh.fail error=\(String(describing: error), privacy: .public)"
            )
            handleRefreshFailure(error)
        }
    }

    private func handleRefreshFailure(_ error: Error) {
        if let linkError = error as? LinkError {
            switch linkError {
            case .httpError(let status, _):
                if status == 401 {
                    signOut()
                    return
                }
                linkingError = linkError.localizedDescription
                resetLinkingStateIfNeeded()
            default:
                linkingError = linkError.localizedDescription
                resetLinkingStateIfNeeded()
            }
            return
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorUserAuthenticationRequired {
                signOut()
            } else {
                linkingError = nsError.localizedDescription
                resetLinkingStateIfNeeded()
            }
            return
        }

        linkingError = error.localizedDescription
        resetLinkingStateIfNeeded()
    }

    func signOut() {
        plexService.signOut()
        keychain.deleteToken(account: keychainAccount)
        session = nil
        isLinked = false
        linkService.setLinked(false)
    }

    private func bootstrapFromKeychain() async {
        let token: String
        do {
            guard let stored = try keychain.readToken(account: keychainAccount) else { return }
            token = stored
        } catch {
            linkingError = error.localizedDescription
            return
        }

        do {
            let devices = try await linkService.fetchResources(authToken: token)
            guard let chosen = linkService.chooseBestServer(devices) else { return }

            let account = try? await linkService.fetchAccount(authToken: token)
            let serverToken = chosen.accessToken.isEmpty ? token : chosen.accessToken

            let connectionURLs = chosen.connections.map { $0.uri }
            guard let primaryURL = connectionURLs.first else { return }

            try await plexService.establishSession(
                accountToken: token,
                serverName: chosen.device.name,
                serverIdentifier: chosen.device.clientIdentifier,
                serverURL: primaryURL,
                fallbackServerURLs: Array(connectionURLs.dropFirst()),
                serverAccessToken: serverToken
            )
            let libraries = plexService.session?.libraries ?? []
            let activeURL = plexService.session?.server.baseURL ?? primaryURL
            let info = PlexSessionInfo(
                authToken: token,
                serverURI: activeURL,
                serverAccessToken: serverToken,
                serverName: chosen.device.name,
                libraryCount: libraries.count,
                accountName: account?.title ?? account?.username ?? "Plex User"
            )
            self.session = info
            isLinked = true
            linkService.setLinked(true)
            if let seeder = channelSeeder {
                Task {
                    await seeder.seedIfNeeded(libraries: libraries)
                }
            }
        } catch {
            keychain.deleteToken(account: keychainAccount)
            linkingError = error.localizedDescription
        }
    }

    private func resetLinkingStateIfNeeded() {
        if plexService.session == nil {
            isLinked = false
            linkService.setLinked(false)
        }
    }

    private func handleSessionUpdate(_ session: PlexService.Session?) {
        if let session {
            let accountName = session.user?.title ?? session.user?.username ?? self.session?.accountName ?? "Plex User"
            let info = PlexSessionInfo(
                authToken: session.accountToken,
                serverURI: session.server.baseURL,
                serverAccessToken: session.server.accessToken,
                serverName: session.server.name,
                libraryCount: session.libraries.count,
                accountName: accountName
            )
            self.session = info
            try? keychain.store(token: info.authToken, account: keychainAccount)
            isLinked = true
            linkService.setLinked(true)
            if let seeder = channelSeeder {
                Task {
                    await seeder.seedIfNeeded(libraries: session.libraries)
                }
            }
        } else {
            self.session = nil
            keychain.deleteToken(account: keychainAccount)
            isLinked = false
            linkService.setLinked(false)
        }
    }
}
