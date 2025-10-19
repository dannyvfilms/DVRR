//
//  PlexLinkServiceTests.swift
//  PlexChannelsTVTests
//
//  Created by Codex on 10/26/25.
//

import XCTest
@testable import PlexChannelsTV

final class PlexLinkServiceTests: XCTestCase {

    func testRemoteEnvironmentPrefersRemoteConnections() {
        let local = ResourceDevice.Connection(
            uri: URL(string: "https://10-0-69-10.example.plex.direct:32400")!,
            local: true,
            relay: false,
            protocolValue: "https"
        )
        let remote = ResourceDevice.Connection(
            uri: URL(string: "https://97-86-8-25.example.plex.direct:32400")!,
            local: false,
            relay: false,
            protocolValue: "https"
        )
        let relay = ResourceDevice.Connection(
            uri: URL(string: "https://45-56-124-90.example.plex.direct:8443")!,
            local: false,
            relay: true,
            protocolValue: "https"
        )

        let device = ResourceDevice(
            name: "Server",
            provides: "server",
            clientIdentifier: "serverID",
            accessToken: "-token-",
            connections: [local, remote, relay],
            publicAddressMatches: false
        )

        let service = makeService()
        let chosen = service.chooseBestServer([device])

        XCTAssertNotNil(chosen)
        XCTAssertEqual(chosen?.connections.count, 3)
        XCTAssertEqual(chosen?.connections.first?.uri, remote.uri)
        XCTAssertEqual(chosen?.connections.last?.uri, relay.uri)
    }

    func testLocalEnvironmentKeepsLocalConnectionsFirst() {
        let local = ResourceDevice.Connection(
            uri: URL(string: "https://10-0-69-10.example.plex.direct:32400")!,
            local: true,
            relay: false,
            protocolValue: "https"
        )
        let remote = ResourceDevice.Connection(
            uri: URL(string: "https://97-86-8-25.example.plex.direct:32400")!,
            local: false,
            relay: false,
            protocolValue: "https"
        )
        let relay = ResourceDevice.Connection(
            uri: URL(string: "https://45-56-124-90.example.plex.direct:8443")!,
            local: false,
            relay: true,
            protocolValue: "https"
        )

        let device = ResourceDevice(
            name: "Server",
            provides: "server",
            clientIdentifier: "serverID",
            accessToken: "-token-",
            connections: [remote, relay, local],
            publicAddressMatches: true
        )

        let service = makeService()
        let chosen = service.chooseBestServer([device])

        XCTAssertNotNil(chosen)
        XCTAssertEqual(chosen?.connections.first?.uri, local.uri)
    }

    private func makeService() -> PlexLinkService {
        PlexLinkService(
            clientIdentifier: "test-client",
            product: "PlexChannelsTV",
            version: "1.0",
            device: "Apple TV",
            platform: "tvOS",
            deviceName: "Unit Test"
        )
    }
}
