//
//  PlexLinkModels.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation

struct PinResponse: Codable {
    let id: Int
    let code: String
    let qr: URL?
    let expiresIn: Int
    let expiresAt: Date
    let authToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        code = try container.decode(String.self, forKey: .code)
        if let value = try? container.decode(Int.self, forKey: .expiresIn) {
            expiresIn = value
        } else if let stringValue = try? container.decode(String.self, forKey: .expiresIn),
                  let parsed = Int(stringValue) {
            expiresIn = parsed
        } else {
            expiresIn = 0
        }

        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)

        if let qrString = try container.decodeIfPresent(String.self, forKey: .qr),
           let url = URL(string: qrString), !qrString.isEmpty {
            qr = url
        } else {
            qr = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case code
        case qr
        case expiresIn
        case expiresAt
        case authToken
    }
}

struct ResourceDevice: Codable {
    let name: String
    let provides: String
    let clientIdentifier: String
    let accessToken: String?
    let connections: [Connection]
    let publicAddressMatches: Bool?

    struct Connection: Codable {
        let uri: URL
        let local: Bool?
        let relay: Bool?
        let protocolValue: String?

        enum CodingKeys: String, CodingKey {
            case uri
            case local
            case relay
            case protocolValue = "protocol"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let uriString = try container.decode(String.self, forKey: .uri)
            guard let uri = URL(string: uriString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .uri,
                    in: container,
                    debugDescription: "Invalid URI string: \(uriString)"
                )
            }

            self.uri = uri
            local = try container.decodeIfPresent(Bool.self, forKey: .local)
            relay = try container.decodeIfPresent(Bool.self, forKey: .relay)
            protocolValue = try container.decodeIfPresent(String.self, forKey: .protocolValue)
        }

        init(
            uri: URL,
            local: Bool?,
            relay: Bool?,
            protocolValue: String?
        ) {
            self.uri = uri
            self.local = local
            self.relay = relay
            self.protocolValue = protocolValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Plex Server"
        provides = try container.decodeIfPresent(String.self, forKey: .provides) ?? ""
        clientIdentifier = try container.decodeIfPresent(String.self, forKey: .clientIdentifier) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        connections = try container.decodeIfPresent([Connection].self, forKey: .connections) ?? []
        if let boolValue = try? container.decode(Bool.self, forKey: .publicAddressMatches) {
            publicAddressMatches = boolValue
        } else if let intValue = try? container.decode(Int.self, forKey: .publicAddressMatches) {
            publicAddressMatches = intValue != 0
        } else if let stringValue = try? container.decode(String.self, forKey: .publicAddressMatches) {
            publicAddressMatches = NSString(string: stringValue).boolValue
        } else {
            publicAddressMatches = nil
        }
    }

    init(
        name: String,
        provides: String,
        clientIdentifier: String,
        accessToken: String?,
        connections: [Connection],
        publicAddressMatches: Bool?
    ) {
        self.name = name
        self.provides = provides
        self.clientIdentifier = clientIdentifier
        self.accessToken = accessToken
        self.connections = connections
        self.publicAddressMatches = publicAddressMatches
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case provides
        case clientIdentifier
        case accessToken
        case connections
        case publicAddressMatches
    }

    var capabilities: Set<String> {
        Set(provides.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}

struct ChosenServer {
    let device: ResourceDevice
    let connections: [ResourceDevice.Connection]
    let accessToken: String
}

struct PlexAccountResponse: Codable {
    let user: PlexAccount
}

struct PlexAccount: Codable {
    let username: String?
    let title: String?
}
