//
//  ResourceXMLParser.swift
//  PlexChannelsTV
//
//  Created by Codex on 10/20/25.
//

import Foundation
import PlexKit

enum ResourceXMLParser {
    static func parseDevices(from data: Data) throws -> [ResourceDevice] {
        let parser = XMLResourceParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser

        guard xmlParser.parse() else {
            throw LinkError.invalidResponse
        }

        return parser.devices
    }
    
}

private final class XMLResourceParser: NSObject, XMLParserDelegate {
    private(set) var devices: [ResourceDevice] = []

    private var currentDeviceAttributes: [String: String] = [:]
    private var currentConnections: [ResourceDevice.Connection] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "Device":
            currentDeviceAttributes = attributeDict
            currentConnections = []
        case "Connection":
            if let uriString = attributeDict["uri"], let uri = URL(string: uriString) {
                let connection = ResourceDevice.Connection(
                    uri: uri,
                    local: attributeDict["local"].flatMap { NSString(string: $0).boolValue },
                    relay: attributeDict["relay"].flatMap { NSString(string: $0).boolValue },
                    protocolValue: attributeDict["protocol"]
                )
                currentConnections.append(connection)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Device" {
            let device = ResourceDevice(
                name: currentDeviceAttributes["name"] ?? "Plex Server",
                provides: currentDeviceAttributes["provides"] ?? "",
                clientIdentifier: currentDeviceAttributes["clientIdentifier"] ?? "",
                accessToken: currentDeviceAttributes["accessToken"],
                connections: currentConnections,
                publicAddressMatches: currentDeviceAttributes["publicAddressMatches"].map { NSString(string: $0).boolValue }
            )
            devices.append(device)
            currentDeviceAttributes = [:]
            currentConnections = []
        }
    }
}
