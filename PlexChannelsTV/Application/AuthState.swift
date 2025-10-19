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

    private let plexService: PlexService
    private let linkService: PlexLinkService
    private let keychain: KeychainStorage
    private let keychainAccount = "plex.auth.token"

    private var cancellables: Set<AnyCancellable> = []

    init(
        plexService: PlexService,
        linkService: PlexLinkService,
        keychain: KeychainStorage = .shared
    ) {
        self.plexService = plexService
        self.linkService = linkService
        self.keychain = keychain

        plexService.$session
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self else { return }
                self?.handleSessionUpdate(session)
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

    func pollPin(id: Int, until deadline: Date) async throws -> String {
        try await linkService.pollPin(id: id, until: deadline)
    }

    func completeLink(authToken: String) async throws {
        let devices = try await linkService.fetchResources(authToken: authToken)
        guard let chosen = linkService.chooseBestServer(devices) else {
            throw LinkError.invalidResponse
        }

        let account = try? await linkService.fetchAccount(authToken: authToken)
        let serverToken = chosen.accessToken.isEmpty ? authToken : chosen.accessToken
        try await plexService.establishSession(
            accountToken: authToken,
            serverName: chosen.device.name,
            serverIdentifier: chosen.device.clientIdentifier,
            serverURL: chosen.connection.uri,
            serverAccessToken: serverToken
        )
        try keychain.store(token: authToken, account: keychainAccount)
        print("[AuthState] Linked to server \(chosen.device.name) at \(chosen.connection.uri.absoluteString)")

        let libraries = plexService.session?.libraries ?? []
        let info = PlexSessionInfo(
            authToken: authToken,
            serverURI: chosen.connection.uri,
            serverAccessToken: serverToken,
            serverName: chosen.device.name,
            libraryCount: libraries.count,
            accountName: account?.title ?? account?.username ?? session?.accountName ?? "Plex User"
        )
        self.session = info
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
    }

    func signOut() {
        plexService.signOut()
        keychain.deleteToken(account: keychainAccount)
        session = nil
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
            try await plexService.establishSession(
                accountToken: token,
                serverName: chosen.device.name,
                serverIdentifier: chosen.device.clientIdentifier,
                serverURL: chosen.connection.uri,
                serverAccessToken: serverToken
            )
            let libraries = plexService.session?.libraries ?? []
            let info = PlexSessionInfo(
                authToken: token,
                serverURI: chosen.connection.uri,
                serverAccessToken: serverToken,
                serverName: chosen.device.name,
                libraryCount: libraries.count,
                accountName: account?.title ?? account?.username ?? "Plex User"
            )
            self.session = info
        } catch {
            keychain.deleteToken(account: keychainAccount)
            linkingError = error.localizedDescription
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
        } else {
            self.session = nil
            keychain.deleteToken(account: keychainAccount)
        }
    }
}
