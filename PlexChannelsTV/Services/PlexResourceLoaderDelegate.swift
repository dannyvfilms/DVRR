//
//  PlexResourceLoaderDelegate.swift
//  PlexChannelsTV
//
//  Created by Codex on 11/1/25.
//

import AVFoundation
import Foundation

/// Resource loader delegate that adds Plex headers to playback requests
/// This ensures sessions appear in app.plex.tv and Plex Dash
final class PlexResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private static let interceptedScheme = "plexhls"
    private let taskQueue = DispatchQueue(label: "PlexResourceLoaderDelegate.tasks")
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let sessionID: String?
    private let token: String
    private let clientIdentifier: String
    private let productName: String
    private let version: String
    private let platform: String
    private let device: String
    private let deviceName: String
    
    init(
        sessionID: String?,
        token: String,
        clientIdentifier: String,
        productName: String,
        version: String,
        platform: String,
        device: String,
        deviceName: String
    ) {
        self.sessionID = sessionID
        self.token = token
        self.clientIdentifier = clientIdentifier
        self.productName = productName
        self.version = version
        self.platform = platform
        self.device = device
        self.deviceName = deviceName
        super.init()
    }

    static func resourceLoaderURL(for url: URL) -> URL {
        let absolute = url.absoluteString
        if absolute.hasPrefix("https://") {
            return URL(string: interceptedScheme + "://" + absolute.dropFirst("https://".count)) ?? url
        }
        if absolute.hasPrefix("http://") {
            return URL(string: interceptedScheme + "://" + absolute.dropFirst("http://".count)) ?? url
        }
        return url
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url else { return false }
        
        // Note: AVFoundation's resource loader may not intercept all HTTPS requests directly
        // For HLS streams, segment requests might bypass the resource loader
        // We primarily rely on headers being set via the transcoder URL parameters and timeline API
        
        // Handle native HTTP/HTTPS requests and custom intercepted HLS URLs.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == Self.interceptedScheme else {
            return false
        }

        let requestURL: URL = {
            guard scheme == Self.interceptedScheme else { return url }
            let absolute = url.absoluteString
            if absolute.hasPrefix(Self.interceptedScheme + "://") {
                return URL(string: "https://" + absolute.dropFirst((Self.interceptedScheme + "://").count)) ?? url
            }
            return url
        }()
        
        // Log when resource loader intercepts a request (for debugging)
        if requestURL.path.contains("transcode") || requestURL.path.contains("m3u8") {
            print("[PlexResourceLoader] Intercepted request: \(requestURL.path)")
        }
        
        // Handle redirects if redirect property is set
        if let redirect = loadingRequest.redirect {
            return handleRedirect(loadingRequest: loadingRequest, redirectRequest: redirect)
        }
        
        // Create a clean GET request to avoid forwarding loader-specific headers that
        // can make Plex treat the HLS startup request as malformed.
        var originalRequest = URLRequest(url: requestURL)
        originalRequest.httpMethod = "GET"
        
        // Add Plex headers (merge with existing headers)
        originalRequest.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        originalRequest.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        originalRequest.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        originalRequest.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        originalRequest.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        originalRequest.setValue(device, forHTTPHeaderField: "X-Plex-Device")
        originalRequest.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        
        // Add session identifier if provided (critical for session tracking)
        if let sessionID {
            originalRequest.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        
        let isStartupRequest = requestURL.path.contains("/video/:/transcode/universal/start.m3u8")
        if !isStartupRequest, let dataRequest = loadingRequest.dataRequest {
            let baseOffset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
            if baseOffset >= 0 {
                if dataRequest.requestsAllDataToEndOfResource {
                    originalRequest.setValue("bytes=\(baseOffset)-", forHTTPHeaderField: "Range")
                } else if dataRequest.requestedLength > 0 {
                    let endOffset = baseOffset + Int64(dataRequest.requestedLength) - 1
                    originalRequest.setValue("bytes=\(baseOffset)-\(endOffset)", forHTTPHeaderField: "Range")
                }
            }
        }
        
        // Perform the request
        let taskID = ObjectIdentifier(loadingRequest)
        let task = URLSession.shared.dataTask(with: originalRequest) { data, response, error in
            self.taskQueue.async {
                self.activeTasks.removeValue(forKey: taskID)
            }
            
            if let error {
                if requestURL.path.contains("transcode") || requestURL.path.contains("m3u8") {
                    print("[PlexResourceLoader] Request failed path=\(requestURL.path) error=\((error as NSError).domain):\((error as NSError).code)")
                }
                loadingRequest.finishLoading(with: error)
                return
            }
            
            guard let data, let response = response as? HTTPURLResponse else {
                let nsError = NSError(domain: "PlexResourceLoader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                loadingRequest.finishLoading(with: nsError)
                return
            }

            let isTranscodeRequest = requestURL.path.contains("transcode") || requestURL.path.contains("m3u8")
            if isTranscodeRequest {
                print("[PlexResourceLoader] Response status=\(response.statusCode) path=\(requestURL.path) bytes=\(data.count) url=\(requestURL.absoluteString)")
            }

            guard (200..<300).contains(response.statusCode) || response.statusCode == 206 else {
                if isTranscodeRequest {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    print("[PlexResourceLoader] Non-2xx status=\(response.statusCode) path=\(requestURL.path) body=\(body)")
                }
                let nsError = NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorBadServerResponse,
                    userInfo: [
                        NSLocalizedDescriptionKey: "HTTP \(response.statusCode) for \(requestURL.path)"
                    ]
                )
                loadingRequest.finishLoading(with: nsError)
                return
            }
            
            // Set content information first (if available)
            if let contentRequest = loadingRequest.contentInformationRequest {
                contentRequest.contentType = response.mimeType ?? "application/octet-stream"
                contentRequest.contentLength = response.expectedContentLength >= 0 ? response.expectedContentLength : Int64(data.count)
                contentRequest.isByteRangeAccessSupported = true
            }
            
            // Provide response data to loading request
            if let dataRequest = loadingRequest.dataRequest {
                dataRequest.respond(with: data)
            }
            
            loadingRequest.response = response
            loadingRequest.finishLoading()
        }

        taskQueue.async {
            self.activeTasks[taskID] = task
        }
        task.resume()
        return true
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForResponseTo authenticationChallenge: URLAuthenticationChallenge
    ) -> Bool {
        // Handle authentication challenges if needed
        return false
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let taskID = ObjectIdentifier(loadingRequest)
        taskQueue.async {
            if let task = self.activeTasks.removeValue(forKey: taskID) {
                task.cancel()
            }
        }
    }
    
    private func handleRedirect(loadingRequest: AVAssetResourceLoadingRequest, redirectRequest: URLRequest) -> Bool {
        // Create a new mutable request from the redirect request
        var newRedirectRequest = redirectRequest
        
        // Add Plex headers to the redirect request
        newRedirectRequest.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        newRedirectRequest.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        newRedirectRequest.setValue(productName, forHTTPHeaderField: "X-Plex-Product")
        newRedirectRequest.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        newRedirectRequest.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        newRedirectRequest.setValue(device, forHTTPHeaderField: "X-Plex-Device")
        newRedirectRequest.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        
        if let sessionID {
            newRedirectRequest.setValue(sessionID, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        
        // Update the redirect request
        loadingRequest.redirect = newRedirectRequest
        
        // Continue with the redirect
        return false  // Let AVFoundation handle the redirect
    }
}
