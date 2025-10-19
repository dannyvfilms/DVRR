//
//  PlexLinkService.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation

final class PlexLinkService {
    private let session: URLSession
    private let clientIdentifier: String
    private let product: String
    private let version: String
    private let device: String
    private let platform: String
    private let deviceName: String

    init(
        session: URLSession = .shared,
        clientIdentifier: String,
        product: String,
        version: String,
        device: String,
        platform: String,
        deviceName: String
    ) {
        self.session = session
        self.clientIdentifier = clientIdentifier
        self.product = product
        self.version = version
        self.device = device
        self.platform = platform
        self.deviceName = deviceName
    }

    private var baseHeaders: [String: String] {
        PlexHeaders.make(
            clientID: clientIdentifier,
            product: product,
            version: version,
            device: device,
            platform: platform,
            deviceName: deviceName
        )
    }

    func requestPin() async throws -> PinResponse {
        var components = URLComponents(string: "https://plex.tv/api/v2/pins")!
        components.queryItems = [
            URLQueryItem(name: "strong", value: "false"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        addHeaders(to: &request, additional: [:])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        logResponse(endpoint: "requestPin", data: data)
        let decoder = makeDecoder()
        return try decoder.decode(PinResponse.self, from: data)
    }

    func pollPin(id: Int, until deadline: Date) async throws -> String {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(id)")!

        while true {
            if Date() >= deadline {
                throw LinkError.pinExpired
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            addHeaders(to: &request, additional: [:])

            let (data, response) = try await session.data(for: request)
            try validate(response: response, data: data)

            logResponse(endpoint: "pollPin", data: data)
            let decoder = makeDecoder()
            let pin = try decoder.decode(PinResponse.self, from: data)

            if let token = pin.authToken, !token.isEmpty {
                return token
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func fetchResources(authToken: String) async throws -> [ResourceDevice] {
        var components = URLComponents(string: "https://plex.tv/api/resources")!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "0"),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"

        addHeaders(to: &request, additional: ["X-Plex-Token": authToken])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        logResponse(endpoint: "fetchResources", data: data)
        if let json = try? makeDecoder().decode([ResourceDevice].self, from: data) {
            return json
        }

        let xmlDevices = try ResourceXMLParser.parseDevices(from: data)
        return xmlDevices
    }

    func fetchAccount(authToken: String) async throws -> PlexAccount {
        var request = URLRequest(url: URL(string: "https://plex.tv/users/account.json")!)
        request.httpMethod = "GET"
        addHeaders(to: &request, additional: ["X-Plex-Token": authToken])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        logResponse(endpoint: "fetchAccount", data: data)

        let decoder = makeDecoder()
        let accountResponse = try decoder.decode(PlexAccountResponse.self, from: data)
        return accountResponse.user
    }

    func chooseBestServer(_ devices: [ResourceDevice]) -> ChosenServer? {
        let serverDevices = devices.filter { $0.capabilities.contains("server") }

        let sorted = serverDevices.sorted { lhs, rhs in
            let lhsPreferred = preferredConnection(for: lhs)
            let rhsPreferred = preferredConnection(for: rhs)
            return score(for: lhsPreferred) > score(for: rhsPreferred)
        }

        guard let device = sorted.first, let connection = preferredConnection(for: device) else {
            return nil
        }

        let serverToken = device.accessToken ?? ""
        return ChosenServer(device: device, connection: connection, accessToken: serverToken)
    }

    private func preferredConnection(for device: ResourceDevice) -> ResourceDevice.Connection? {
        let httpsConnections = device.connections.filter { $0.uri.scheme?.lowercased() == "https" }

        let sorted = httpsConnections.sorted { lhs, rhs in
            score(for: lhs) > score(for: rhs)
        }

        return sorted.first ?? device.connections.first
    }

    private func score(for connection: ResourceDevice.Connection?) -> Int {
        guard let connection else { return -1 }
        var score = 0
        if connection.local == true { score += 4 }
        if connection.relay == false { score += 2 }
        if connection.uri.scheme?.lowercased() == "https" { score += 1 }
        return score
    }

    private func addHeaders(to request: inout URLRequest, additional: [String: String]) {
        let headers = baseHeaders.merging(additional) { _, new in new }
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LinkError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LinkError.httpError(status: httpResponse.statusCode, body: body)
        }
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = Self.iso8601WithFractional.date(from: value) ?? Self.iso8601NoFraction.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(value)")
        }
        return decoder
    }

    private func logResponse(endpoint: String, data: Data) {
#if DEBUG
        if let body = String(data: data, encoding: .utf8) {
            print("[PlexLinkService] \(endpoint) response: \(body)")
        } else {
            print("[PlexLinkService] \(endpoint) response (non-utf8, \(data.count) bytes)")
        }
#endif
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

enum LinkError: LocalizedError {
    case pinExpired
    case invalidResponse
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .pinExpired:
            return "The linking code has expired."
        case .invalidResponse:
            return "Received an unexpected response from Plex."
        case .httpError(let status, let body):
            return "Plex returned an error (\(status)): \(body)"
        }
    }
}
